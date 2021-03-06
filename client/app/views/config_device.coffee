BaseView = require 'lib/base_view'

# Row displaying device name and attributes
module.exports = class DeviceRow extends BaseView
    className: "config-device"
    tagName: "div"
    template: require 'templates/config_device'

    events:
        'click .remove-device': 'onRemoveClicked'

    getRenderData: ->
        device: @model.attributes

    constructor: (options) ->
        @model = options.model
        @id = "device-btn-#{options.model.id}"
        super

    onRemoveClicked: (event) ->
        if window.confirm t 'revoke device confirmation message'
            $(event.currentTarget).spin true
            $.ajax("/api/devices/#{@model.get('id')}",
                type: "DELETE"
                success: =>
                    @$el.fadeOut ->
                error: =>
                    @$('.remove-device').html t 'revoke device access'
                    console.log "error while revoking the device access"
            )
