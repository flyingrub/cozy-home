request = require("request-json")
fs = require('fs')
slugify = require 'cozy-slug'
log = require('printit')
    prefix: "applications"

Application = require '../models/application'
{AppManager} = require '../lib/paas'
{Manifest} = require '../lib/manifest'

# Small hack to ensure that an user doesn't try to start an application twice
# at the same time. We store there the ID of apps which are already started.
# IDs are the keys, values are all equal to true.
startedApplications = {}

# Helpers

sendError = (res, err, code=500) ->
    err ?=
        stack:   null
        message: "Server error occured"

    console.log "Sending error to client :"
    console.log err.stack

    res.send code,
        error: true
        success: false
        message: err.message
        stack: err.stack

sendErrorSocket = (err) ->
    console.log "Sending error through socket"
    console.log err.stack

markBroken = (res, app, err) ->
    console.log "Marking app #{app.name} as broken because"
    console.log err.stack

    app.state = "broken"
    app.password = null
    app.errormsg = err.message
    app.save (saveErr) ->
        return sendError res, saveErr if saveErr

        res.send
            app: app
            error: true
            success: false
            message: err.message
            stack: err.stack
        , 500

# Define random function for application's token
randomString = (length) ->
    string = ""
    while (string.length < length)
        string = string + Math.random().toString(36).substr(2)
    return string.substr 0, length

# Save an app's icon in the DS
saveIcon = (appli, callback = ->) ->
    if appli? and appli.port?
        client = request.newClient "http://localhost:#{appli.port}/"
        tmpName = "/tmp/icon_#{appli.slug}.png"
        client.saveFile "icons/main_icon.png", tmpName, (err, res, body) ->
            return callback err if err
            appli.attachFile tmpName, name: 'icon.png', (err) ->
                fs.unlink tmpName
                return callback err if err
                callback null
    else
        callback new Error 'Appli cannot be reached'


module.exports =


    # Load application corresponding to slug given in params
    loadApplication: (req, res, next, slug) ->
        Application.all key: req.params.slug, (err, apps) ->
            if err
                next err
            else if apps is null or apps.length is 0
                res.send 404, error: 'Application not found'
            else
                req.application = apps[0]
                next()


    applications: (req, res, next) ->
        Application.all (err, apps) ->
            if err then next err
            else res.send rows: apps


    getPermissions: (req, res, next) ->
        manifest = new Manifest()
        manifest.download req.body, (err) ->
            if err then next err
            app = permissions: manifest.getPermissions()
            res.send success: true, app: app


    getDescription: (req, res, next) ->
        manifest = new Manifest()
        manifest.download req.body, (err) ->
            if err then next err
            app = description: manifest.getDescription()
            res.send success: true, app: app


    getMetaData: (req, res, next) ->
        manifest = new Manifest()
        manifest.download req.body, (err) ->
            if err then next err
            metaData = manifest.getMetaData()
            res.send success: true, app: metaData, 200


    read: (req, res, next) ->
        Application.find req.params.id, (err, app) ->
            if err then sendError res, err
            else if app is null
                sendError res, new Error('Application not found'), 404
            else
                res.send app


    icon: (req, res, next) ->
        if req.application?._attachments?['icon.png']
            return req.application.getFile('icon.png', (->)).pipe res

        # else, do the attaching (apps installed before)
        # FOR MIGRATION, REMOVE ME LATER
        saveIcon req.application, (err) =>
            if err
                return fs.createReadStream('./client/app/assets/img/stopped.png').pipe res
            req.application.getFile('icon.png', (->)).pipe res


    updatestoppable: (req, res, next) ->
        Application.find req.params.id, (err, app) ->
            if err
                sendError res, err
            else if app is null
                sendError res, new Error('Application not found'), 404
            else
                Stoppable = req.body.isStoppable
                Stoppable = if Stoppable? then Stoppable else app.isStoppable
                changes =
                    homeposition: req.body.homeposition or app.homeposition
                    isStoppable: Stoppable
                app.updateAttributes changes, (err, app) ->
                    return sendError res, err if err
                    res.send app


    # Set up app into 3 places :
    # * haibu, application manager
    # * proxy, cozy router
    # * database
    # Send an error if an application already has same slug.
    install: (req, res, next) ->
        req.body.slug = slugify req.body.name
        req.body.state = "installing"
        req.body.password = randomString 32

        Application.all key: req.body.slug, (err, apps) ->
            return sendError res, err if err

            if apps.length > 0 or req.body.slug is "proxy" or
                    req.body.slug is "home" or req.body.slug is "data-system"
                err = new Error "already similarly named app"
                return sendError res, err, 400

            manifest = new Manifest()
            manifest.download req.body, (err) ->
                return sendError res, err if err
                req.body.permissions = manifest.getPermissions()
                req.body.widget = manifest.getWidget()
                req.body.version = manifest.getVersion()

                Application.create req.body, (err, appli) ->
                    return sendError res, err if err

                    res.send success: true, app: appli, 201

                    infos = JSON.stringify appli
                    console.info "attempt to install app #{infos}"
                    manager = new AppManager()
                    manager.installApp appli, (err, result) ->
                        if err
                            markBroken res, appli, err
                            sendErrorSocket err
                            return

                        if result.drone?
                            appli.state = "installed"
                            appli.port = result.drone.port

                            msg = "install succeeded on port #{appli.port}"
                            console.info msg

                            saveIcon appli, (err) ->
                                if err then console.log err.stack
                                else console.info 'icon attached'

                            appli.save (err) ->
                                return sendErrorSocket err if err
                                console.info 'saved port in db', appli.port
                                manager.resetProxy (err) ->
                                    return sendErrorSocket err if err
                                    console.info 'proxy reset', appli.port

                        else
                            err = new Error "Controller has no " + \
                                            "informations about #{appli.name}"
                            return sendErrorSocket err if err


    # Remove app from 3 places :
    # * haibu, application managerll
    # * proxy, cozy router
    # * database
    uninstall: (req, res, next) ->
        req.body.slug = req.params.slug
        manager = new AppManager()
        manager.uninstallApp req.application, (err, result) ->
            return markBroken res, req.application, err if err

            req.application.destroy (err) ->
                return sendError res, err if err

                manager.resetProxy (err) ->
                    return sendError res, proxyErr if err

                    res.send
                        success: true
                        msg: 'Application succesfuly uninstalled'


    # Update an app :
    # * haibu, application manager
    # * proxy, cozy router
    # * database
    update: (req, res, next) ->
        manager = new AppManager()
        if not req.application.password?
            req.application.password = randomString 32

        manager.updateApp req.application, (err, result) ->
            return markBroken res, req.application, err if err
            req.application.state = "installed"

            manifest = new Manifest()
            manifest.download req.application, (err) =>
                return sendError res, err if err
                req.application.permissions = manifest.getPermissions()
                req.application.widget = manifest.getWidget()
                req.application.version = manifest.getVersion()
                req.application.needsUpdate = false
                req.application.save (err) ->

                    saveIcon req.application, (err) ->
                        if err then console.log err.stack
                        else console.info 'icon attached'

                    return sendError res, err if err

                    manager.resetProxy (err) ->
                        return markBroken res, req.application, err if err

                        res.send
                            success: true
                            msg: 'Application succesfuly updated'




    # Update all applications :
    # * haibu, application manager
    # * proxy, cozy router
    # * database
    updateAll: (req, res, next) ->   
        totalApp = 0
        updatedApp = 0 
        updateApp = (app, callback) ->
            manager = new AppManager()
            if not app.password?
                app.password = randomString 32

            manager.updateApp app, (err, result) ->
                callback err if err?
                app.state = "installed"

                manifest = new Manifest()
                manifest.download app, (err) =>
                    callback err if err?
                    app.permissions = manifest.getPermissions()
                    app.widget = manifest.getWidget()
                    app.version = manifest.getVersion()
                    app.needsUpdate = false
                    app.save (err) ->
                        saveIcon app, (err) ->
                            if err then console.log err.stack
                            else console.info 'icon attached'
                        callback err if err
                        manager.resetProxy (err) ->
                            callback()
        checkupdate = () =>
            if totalApp > updatedApp
                setTimeout () =>
                    checkupdate()
                , 500
            else
                res.send
                    success: true
                    msg: 'Applications succesfuly updated'

        Application.all (err, apps) =>
            totalApp = apps.length
            for app in apps               
                switch app.state
                    when "installed"
                        # Update application 
                        console.log("installed #{app.name}")
                        updateApp app, (err) =>
                            return markBroken res, app, err if err
                            updatedApp = updatedApp + 1 
                    when "stopped"
                        # Start application
                        console.log("stopped #{app.name}")
                        manager = new AppManager
                        manager.start app, (err, result) ->
                            return markBroken res, app, err if err
                            # Update application
                            updateApp app, (err) =>
                                return markBroken res, app, err if err
                                # Stop application
                                manager.stop app, (err, result) ->
                                    return markBroken res, app, err if err
                                    updatedApp = updatedApp + 1 
                    else
                        # Application state is broken or installing
                        updatedApp = updatedApp + 1 
            checkupdate()

    # Start a stopped application.
    start: (req, res, next) ->
        # If controller is too slow, client receives a timeout
        # Below timeout allows to catch timeout error before client
        # If there is a timeout, application is consider like broken
        setTimeout () ->
            if startedApplications[req.application.id]?
                delete startedApplications[req.application.id]
                return markBroken res, req.application,
                    stack: "Installation timeout",
                    message: "Installation timeout"

        , 45 * 1000


        unless startedApplications[req.application.id]?
            startedApplications[req.application.id] = true

            manager = new AppManager
            manager.start req.application, (err, result) ->
                if err
                    delete startedApplications[req.application.id]
                    return markBroken res, req.application, err

                req.application.state = "installed"
                req.application.port = result.drone.port
                req.application.save (err) ->
                    if err
                        delete startedApplications[req.application.id]
                        return markBroken res, req.application, err

                    manager.resetProxy (err) ->
                        delete startedApplications[req.application.id]

                        if err
                            markBroken res, req.application, err
                        else
                            res.send
                                success: true
                                msg: 'Application running'
                                app: req.application

        else
            res.send
                error: true
                msg: 'Application is already starting'
                app: req.application


    stop: (req, res, next) ->
        manager = new AppManager
        manager.stop req.application, (err, result) ->
            return markBroken res, req.application, err if err

            data =
                state: 'stopped'
                port : 0

            req.application.updateAttributes data, (err) ->
                return sendError res, err if err

                manager.resetProxy (err) ->
                    return markBroken res, req.application, err if err
                    res.send
                        success: true
                        msg: 'Application stopped'
                        app: req.application
