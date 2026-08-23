import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Sensor;

class glucoguardView extends WatchUi.View {

    var heartRate = null;

    function initialize() {
        View.initialize();
    }

    function onShow() {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensorData));
    }

    function onHide() {
        Sensor.enableSensorEvents(null);
        Sensor.setEnabledSensors([]);
    }

    function onUpdate(dc) {
        View.onUpdate(dc);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var hrText = (heartRate == null) ? "--" : heartRate.toString();

        dc.drawText(
            dc.getWidth() / 2,
            (dc.getHeight() / 2) - 20,
            Graphics.FONT_LARGE,
            hrText,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        dc.drawText(
            dc.getWidth() / 2,
            (dc.getHeight() / 2) + 30,
            Graphics.FONT_SMALL,
            "BPM",
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heartRate != null) {
            heartRate = sensorInfo.heartRate;
        }

        WatchUi.requestUpdate();
    }
}