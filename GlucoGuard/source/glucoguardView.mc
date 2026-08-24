import Toybox.Graphics;
import Toybox.Timer;
import Toybox.WatchUi;
import Toybox.Sensor;

class glucoguardView extends WatchUi.View {

    const SNAPSHOT_DURATION_SEC = 240;

    var heartRate = null;
    var snapshotActive = false;
    var snapshotStartTime = null;
    var snapshotSecondsRemaining = SNAPSHOT_DURATION_SEC;
    var snapshotDone = false;
    var snapshotTimer = null;

    function initialize() {
        View.initialize();
        snapshotTimer = new Timer.Timer();
    }

    function onShow() {
    }

    function onHide() {
        stopSnapshotTimer();
        stopHeartRateRead();
    }

    function startSnapshot() as Void {
        snapshotActive = true;
        snapshotDone = false;
        snapshotStartTime = Time.now();
        snapshotSecondsRemaining = SNAPSHOT_DURATION_SEC;
        heartRate = null;
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensorData));
        snapshotTimer.start(method(:onSnapshotTick), 1000, true);
        WatchUi.requestUpdate();
    }

    function cancelSnapshot() as Void {
        stopSnapshotTimer();
        snapshotActive = false;
        snapshotDone = false;
        snapshotStartTime = null;
        snapshotSecondsRemaining = SNAPSHOT_DURATION_SEC;
        heartRate = null;
        stopHeartRateRead();
        WatchUi.requestUpdate();
    }

    function stopHeartRateRead() as Void {
        Sensor.enableSensorEvents(null);
        Sensor.setEnabledSensors([]);
    }

    function stopSnapshotTimer() as Void {
        if (snapshotTimer != null) {
            snapshotTimer.stop();
        }
    }

    function onSnapshotTick() as Void {
        if (!snapshotActive) {
            return;
        }

        snapshotSecondsRemaining -= 1;
        if (snapshotSecondsRemaining <= 0) {
            snapshotSecondsRemaining = 0;
            snapshotActive = false;
            snapshotDone = true;
            stopSnapshotTimer();
            heartRate = null;
            stopHeartRateRead();
        }

        WatchUi.requestUpdate();
    }

    function handlePrimaryAction() as Void {
        if (snapshotActive) {
            cancelSnapshot();
        } else if (!snapshotDone) {
            startSnapshot();
        }
    }

    function formatCountdown() {
        var minutes = snapshotSecondsRemaining / 60;
        var seconds = snapshotSecondsRemaining % 60;
        var secondsText = (seconds < 10) ? "0" + seconds.toString() : seconds.toString();
        return minutes.toString() + ":" + secondsText;
    }

    function onUpdate(dc) {
        View.onUpdate(dc);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var stateText = "Start Snapshot";
        if (snapshotActive) {
            stateText = formatCountdown();
        } else if (snapshotDone) {
            stateText = "Done";
        }

        var hrText = "";
        if (snapshotActive) {
            hrText = (heartRate == null) ? "-- BPM" : heartRate.toString() + " BPM";
        }

        dc.drawText(
            dc.getWidth() / 2,
            (dc.getHeight() / 2) - (snapshotActive ? 70 : 20),
            Graphics.FONT_LARGE,
            stateText,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        if (snapshotActive) {
            dc.drawText(
                dc.getWidth() / 2,
                (dc.getHeight() / 2) - 5,
                Graphics.FONT_SMALL,
                hrText,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        var actionText = "SELECT: Start";
        if (snapshotActive) {
            actionText = "SELECT: Cancel";
        }

        dc.drawText(
            dc.getWidth() / 2,
            (dc.getHeight() / 2) + (snapshotActive ? 70 : 30),
            Graphics.FONT_SMALL,
            actionText,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (!snapshotActive) {
            return;
        }

        if (sensorInfo.heartRate != null) {
            heartRate = sensorInfo.heartRate;
        }

        WatchUi.requestUpdate();
    }
}

class glucoguardInputDelegate extends WatchUi.BehaviorDelegate {

    var view;

    function initialize(viewToControl) {
        BehaviorDelegate.initialize();
        view = viewToControl;
    }

    function onSelect() {
        view.handlePrimaryAction();
        return true;
    }
}