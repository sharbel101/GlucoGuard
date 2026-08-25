import Toybox.Graphics;
import Toybox.Timer;
import Toybox.WatchUi;
import Toybox.Sensor;

class glucoguardView extends WatchUi.View {

    const SNAPSHOT_DURATION_SEC = 240;
    const HR_BUFFER_INTERVAL_SEC = 4;
    const HR_BUFFER_MAX = 90;

    var heartRate = null;
    var snapshotActive = false;
    var snapshotStartTime = null;
    var snapshotSecondsRemaining = SNAPSHOT_DURATION_SEC;
    var snapshotDone = false;
    var snapshotTimer = null;
    var hrBuffer = [];

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
        hrBuffer = [];
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

        var secondsElapsed = SNAPSHOT_DURATION_SEC - snapshotSecondsRemaining;
        if (secondsElapsed % HR_BUFFER_INTERVAL_SEC == 0 && hrBuffer.size() < HR_BUFFER_MAX) {
            hrBuffer.add({ :t => Time.now().value(), :hr => heartRate });
        }

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

    function computeHrSlope() {
        if (hrBuffer.size() < 2) {
            return null;
        }

        var oldest = hrBuffer[0];
        var newest = hrBuffer[hrBuffer.size() - 1];

        if (oldest[:hr] == null || newest[:hr] == null) {
            return null;
        }

        var minutesElapsed = (newest[:t] - oldest[:t]) / 60.0;
        if (minutesElapsed == 0) {
            return 0;
        }

        return (newest[:hr] - oldest[:hr]) / minutesElapsed;
    }

    function formatHrSlope(slope) {
        if (slope == null) {
            return "-- bpm/min";
        }

        var sign = (slope >= 0) ? "+" : "";
        return sign + slope.format("%.1f") + " bpm/min";
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

        var centerX = dc.getWidth() / 2;
        dc.drawText(
            centerX,
            24,
            Graphics.FONT_SMALL,
            "GLUCOGUARD",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        var actionText = "START";
        var statusText = "READY TO CHECK";
        if (snapshotActive) {
            statusText = "CAPTURING NOW";
            actionText = "CANCEL";
        } else if (snapshotDone) {
            statusText = "SNAPSHOT COMPLETE";
            actionText = "AGAIN";
        }

        dc.drawText(
            centerX,
            62,
            Graphics.FONT_SMALL,
            statusText,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        if (snapshotActive) {
            dc.drawText(
                centerX,
                (dc.getHeight() / 2) - 78,
                Graphics.FONT_LARGE,
                formatCountdown(),
                Graphics.TEXT_JUSTIFY_CENTER
            );

            var hrText = (heartRate == null) ? "-- BPM" : heartRate.toString() + " BPM";
            dc.drawText(
                centerX,
                (dc.getHeight() / 2) - 30,
                Graphics.FONT_SMALL,
                hrText,
                Graphics.TEXT_JUSTIFY_CENTER
            );

            // DEBUG: buffer size, remove once Step 3 is verified
            dc.drawText(
                centerX,
                (dc.getHeight() / 2) + 4,
                Graphics.FONT_XTINY,
                "buf " + hrBuffer.size().toString(),
                Graphics.TEXT_JUSTIFY_CENTER
            );

            dc.drawText(
                centerX,
                (dc.getHeight() / 2) + 28,
                Graphics.FONT_XTINY,
                formatHrSlope(computeHrSlope()),
                Graphics.TEXT_JUSTIFY_CENTER
            );
        } else {
            var stateText = snapshotDone ? "Done" : "Start Snapshot";
            dc.drawText(
                centerX,
                (dc.getHeight() / 2) - 48,
                Graphics.FONT_MEDIUM,
                stateText,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        var buttonX = 48;
        var buttonY = (dc.getHeight() / 2) + 66;
        var buttonWidth = dc.getWidth() - 96;
        var buttonHeight = 50;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.fillRoundedRectangle(buttonX, buttonY, buttonWidth, buttonHeight, 16);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_WHITE);
        dc.drawText(
            centerX,
            buttonY + 15,
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

    function onTap(clickEvent) {
        var coordinates = clickEvent.getCoordinates();
        var buttonY = (view.getHeight() / 2) + 66;
        if (coordinates[0] >= 48 && coordinates[0] <= view.getWidth() - 48 &&
            coordinates[1] >= buttonY && coordinates[1] <= buttonY + 50) {
            view.handlePrimaryAction();
            return true;
        }

        return false;
    }
}