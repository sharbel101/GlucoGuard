import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class glucoguardView extends WatchUi.View {

    // ------------------------------------------------------------------
    // Capture configuration (unchanged)
    // ------------------------------------------------------------------
    const SNAPSHOT_DURATION_SEC = 240;
    const HR_BUFFER_INTERVAL_SEC = 4;
    const HR_BUFFER_MAX = 90;

    // ------------------------------------------------------------------
    // Palette
    //
    // vivoactive6 is AMOLED, so custom hex reads far better than the 15
    // named Graphics.COLOR_* constants. One accent colour per state so the
    // three states are distinguishable before any text is read.
    // ------------------------------------------------------------------
    const C_BG      = 0x000000;
    const C_TRACK   = 0x353A42;   // empty ring track
    const C_MUTED   = 0x8B919C;   // secondary / metadata text
    const C_TEXT    = 0xFFFFFF;
    const C_READY   = 0x4DA3FF;   // idle accent
    const C_LIVE    = 0x1E9BE9;   // capture-in-progress accent
    const C_DONE    = 0x21C97A;   // completed accent
    const C_DANGER  = 0xE03131;   // cancel / stop
    const C_HEART   = 0xE8384F;   // heart glyph
    const C_RISING  = 0xF5A524;   // HR trending up
    const C_FALLING = 0x4DA3FF;   // HR trending down

    // bpm/min inside this band is treated as "flat"
    const SLOPE_FLAT_BAND = 1.5;

    // ------------------------------------------------------------------
    // State (unchanged)
    // ------------------------------------------------------------------
    var heartRate = null;
    var snapshotActive = false;
    var snapshotStartTime = null;
    var snapshotSecondsRemaining = SNAPSHOT_DURATION_SEC;
    var snapshotDone = false;
    var snapshotTimer = null;
    var hrBuffer = [];

    // Hit box of the on-screen action button as [x, y, w, h]. Refreshed on
    // every draw so the input delegate never has to re-derive the layout.
    var buttonBounds = null;

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

    // ==================================================================
    // Capture lifecycle (logic unchanged)
    // ==================================================================

    function startSnapshot() as Void {
        snapshotActive = true;
        snapshotDone = false;
        snapshotStartTime = Time.now();
        snapshotSecondsRemaining = SNAPSHOT_DURATION_SEC;
        heartRate = null;
        hrBuffer = [];
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensorData));
        var sensorOptions = { :heartBeatIntervals => { :enabled => true } };
        Sensor.registerSensorDataListener(method(:onSensorData), sensorOptions);
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
        Sensor.unregisterSensorDataListener();
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

    // FIX: the old version was `else if (!snapshotDone)`, which meant the
    // button drawn in the completed state ("AGAIN") did nothing at all.
    // startSnapshot() already clears snapshotDone, so a plain else is correct.
    function handlePrimaryAction() as Void {
        if (snapshotActive) {
            cancelSnapshot();
        } else {
            startSnapshot();
        }
    }

    function onSensorData(sensorData) as Void {
        if (!snapshotActive) {
            return;
        }

        if (sensorData.heartRate != null) {
            heartRate = sensorData.heartRate;
        }

        if (sensorData.heartRateData != null) {
            System.println("HR Data: " + sensorData.heartRateData.toString());
            if (sensorData.heartRateData.heartBeatIntervals != null) {
                var intervals = sensorData.heartRateData.heartBeatIntervals;
                System.println("HRV Beat-to-beat intervals: " + intervals.toString());
            }
        }

        WatchUi.requestUpdate();
    }

    // ==================================================================
    // Derived values
    // ==================================================================

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

    function averageHr() {
        var sum = 0;
        var count = 0;
        for (var i = 0; i < hrBuffer.size(); i += 1) {
            var sample = hrBuffer[i][:hr];
            if (sample != null) {
                sum += sample;
                count += 1;
            }
        }
        if (count == 0) {
            return null;
        }
        return sum / count;
    }

    function validSampleCount() {
        var count = 0;
        for (var i = 0; i < hrBuffer.size(); i += 1) {
            if (hrBuffer[i][:hr] != null) {
                count += 1;
            }
        }
        return count;
    }

    // -1 falling, 0 flat, +1 rising
    function slopeDirection(slope) {
        if (slope == null) {
            return 0;
        }
        if (slope > SLOPE_FLAT_BAND) {
            return 1;
        }
        if (slope < -SLOPE_FLAT_BAND) {
            return -1;
        }
        return 0;
    }

    function slopeColor(direction) {
        if (direction > 0) {
            return C_RISING;
        }
        if (direction < 0) {
            return C_FALLING;
        }
        return C_MUTED;
    }

    function formatHrSlope(slope) {
        if (slope == null) {
            return "--";
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

    // 0.0 -> 1.0 through the capture window
    function captureProgress() {
        var elapsed = SNAPSHOT_DURATION_SEC - snapshotSecondsRemaining;
        return elapsed / (SNAPSHOT_DURATION_SEC * 1.0);
    }

    // ==================================================================
    // Drawing primitives
    // ==================================================================

    function drawCenteredText(dc, x, y, font, str, color) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            x,
            y,
            font,
            str,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // Full ring used as the "empty" track behind any progress.
    function drawTrack(dc, cx, cy, radius, penWidth) as Void {
        dc.setPenWidth(penWidth);
        dc.setColor(C_TRACK, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, radius);
    }

    // Progress fills clockwise from 12 o'clock. In Connect IQ 90 degrees is
    // 12 o'clock and angles increase counter-clockwise, so sweeping clockwise
    // means counting the end angle down from 90 and wrapping past zero.
    function drawProgressArc(dc, cx, cy, radius, penWidth, progress, color) as Void {
        if (progress <= 0.0) {
            return;
        }

        dc.setPenWidth(penWidth);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        if (progress >= 0.999) {
            dc.drawCircle(cx, cy, radius);
            return;
        }

        var endDeg = 90.0 - (360.0 * progress);
        while (endDeg < 0.0) {
            endDeg += 360.0;
        }

        dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 90, endDeg.toNumber());
    }

    // direction: -1 falling, 0 flat, +1 rising
    function drawTrendArrow(dc, x, y, size, direction, color) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        if (direction == 0) {
            dc.fillRectangle(x - size, y - (size / 3), size * 2, (size / 3) * 2);
            return;
        }

        if (direction > 0) {
            dc.fillPolygon([
                [x, y - size],
                [x - size, y + size],
                [x + size, y + size]
            ]);
        } else {
            dc.fillPolygon([
                [x, y + size],
                [x - size, y - size],
                [x + size, y - size]
            ]);
        }
    }

    // Two lobes plus a triangle. `size` is roughly the half-width, and
    // `centerY` is the glyph's optical centre, not its construction origin
    // (the shape runs -0.89 to +1.05 of size, so the origin sits above it).
    function drawHeart(dc, cx, centerY, size, color) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        var cy = centerY - (size * 0.08).toNumber();
        var lobeR = (size * 0.55).toNumber();
        var lobeDx = (size * 0.50).toNumber();
        var lobeDy = (size * 0.34).toNumber();

        dc.fillCircle(cx - lobeDx, cy - lobeDy, lobeR);
        dc.fillCircle(cx + lobeDx, cy - lobeDy, lobeR);

        dc.fillPolygon([
            [cx - size, cy - (size * 0.20).toNumber()],
            [cx + size, cy - (size * 0.20).toNumber()],
            [cx, cy + (size * 1.05).toNumber()]
        ]);
    }

    // Geometry only, so callers can reserve the space before drawing.
    function buttonRect(w, h) {
        var bw = (w * 0.40).toNumber();
        var bh = (h * 0.125).toNumber();
        return [(w / 2) - (bw / 2), (h * 0.79).toNumber() - (bh / 2), bw, bh];
    }

    function drawActionButton(dc, w, h, label, fillColor, labelColor) as Void {
        var rect = buttonRect(w, h);

        dc.setColor(fillColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(rect[0], rect[1], rect[2], rect[3], rect[3] / 2);

        drawCenteredText(
            dc, w / 2, rect[1] + (rect[3] / 2),
            Graphics.FONT_SMALL, label, labelColor
        );

        buttonBounds = rect;
    }

    // Draws title + status stacked by real font height and returns the y of
    // the header's bottom edge, which becomes the top of the content band.
    function drawHeader(dc, w, h, statusText, statusColor) {
        var lineHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var gap = (h * 0.012).toNumber();
        var y = (h * 0.095).toNumber() + (lineHeight / 2);

        drawCenteredText(dc, w / 2, y, Graphics.FONT_XTINY, "GLUCOGUARD", C_MUTED);
        y += lineHeight + gap;
        drawCenteredText(dc, w / 2, y, Graphics.FONT_XTINY, statusText, statusColor);

        return y + (lineHeight / 2);
    }

    // Centre a vertical stack of items of the given heights inside a band and
    // return each item's centre y. Positions come from measured heights, so
    // elements cannot collide no matter how tall a font turns out to be.
    function stackCenters(bandTop, bandBottom, heights, gap) {
        var count = heights.size();
        var total = gap * (count - 1);
        for (var i = 0; i < count; i += 1) {
            total += heights[i];
        }

        // If the stack somehow still exceeds the band, start flush with the
        // top rather than centring, so it can never ride up into the header.
        var offset = ((bandBottom - bandTop) - total) / 2;
        if (offset < 0) {
            offset = 0;
        }

        var y = bandTop + offset;
        var centers = new [count];
        for (var i = 0; i < count; i += 1) {
            centers[i] = y + (heights[i] / 2);
            y += heights[i] + gap;
        }
        return centers;
    }

    // Largest number font whose stack still fits the band.
    function fitHeroFont(dc, bandHeight, otherHeights, gap, candidates) {
        // n items -> n-1 gaps; otherHeights.size() gaps once the hero joins.
        var overhead = gap * otherHeights.size();
        for (var i = 0; i < otherHeights.size(); i += 1) {
            overhead += otherHeights[i];
        }

        for (var i = 0; i < candidates.size(); i += 1) {
            if (dc.getFontHeight(candidates[i]) + overhead <= bandHeight) {
                return candidates[i];
            }
        }
        return candidates[candidates.size() - 1];
    }

    // Arrow + slope text as one optically centred row.
    function drawTrendRow(dc, w, y, slope) as Void {
        var direction = slopeDirection(slope);
        var color = slopeColor(direction);
        var label = formatHrSlope(slope);

        var arrowSize = (w * 0.022).toNumber();
        var gap = (w * 0.025).toNumber();
        var textWidth = dc.getTextWidthInPixels(label, Graphics.FONT_XTINY);
        var totalWidth = (arrowSize * 2) + gap + textWidth;
        var startX = (w / 2) - (totalWidth / 2);

        drawTrendArrow(dc, startX + arrowSize, y, arrowSize, direction, color);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            startX + (arrowSize * 2) + gap,
            y,
            Graphics.FONT_XTINY,
            label,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // ==================================================================
    // States
    // ==================================================================

    function onUpdate(dc) {
        View.onUpdate(dc);

        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }

        dc.setColor(C_TEXT, C_BG);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        // The ring runs flush to the edge of the drawable area. Note the
        // watch renders a black bezel of roughly 20px OUTSIDE getWidth(), so
        // there is always some apparent margin that cannot be drawn into --
        // padding here only adds to it. Keep edgePad near zero.
        var shorter = (w < h) ? w : h;
        var penWidth = (w * 0.042).toNumber();
        var edgePad = (w * 0.006).toNumber();
        var radius = (shorter / 2) - edgePad - (penWidth / 2);

        if (snapshotActive) {
            drawCapturingState(dc, w, h, cx, cy, radius, penWidth);
        } else if (snapshotDone) {
            drawDoneState(dc, w, h, cx, cy, radius, penWidth);
        } else {
            drawReadyState(dc, w, h, cx, cy, radius, penWidth);
        }
    }

    // ---- READY -------------------------------------------------------
    // Hero: the heart glyph — this screen's job is identity plus a clear
    // call to action, and there is no live value to show yet.
    function drawReadyState(dc, w, h, cx, cy, radius, penWidth) as Void {
        drawTrack(dc, cx, cy, radius, penWidth);

        var bandTop = drawHeader(dc, w, h, "READY", C_READY) + (h * 0.024).toNumber();
        var bandBottom = buttonRect(w, h)[1] - (h * 0.024).toNumber();

        var lineHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var heartSize = (w * 0.075).toNumber();
        var gap = (h * 0.024).toNumber();

        var rows = stackCenters(
            bandTop, bandBottom,
            [(heartSize * 1.94).toNumber(), lineHeight, lineHeight],
            gap
        );

        drawHeart(dc, cx, rows[0], heartSize, C_HEART);
        drawCenteredText(dc, cx, rows[1], Graphics.FONT_XTINY, "4 MIN SCAN", C_TEXT);
        drawCenteredText(dc, cx, rows[2], Graphics.FONT_XTINY, "NOT A MEDICAL DEVICE", C_MUTED);

        drawActionButton(dc, w, h, "START", C_READY, C_BG);
    }

    // ---- CAPTURING ---------------------------------------------------
    // Hero: live heart rate. The ring carries elapsed time, so the digits
    // are demoted to a secondary line.
    function drawCapturingState(dc, w, h, cx, cy, radius, penWidth) as Void {
        drawTrack(dc, cx, cy, radius, penWidth);
        drawProgressArc(dc, cx, cy, radius, penWidth, captureProgress(), C_LIVE);

        var bandTop = drawHeader(dc, w, h, "CAPTURING", C_LIVE) + (h * 0.024).toNumber();
        var bandBottom = buttonRect(w, h)[1] - (h * 0.024).toNumber();

        var countdownHeight = dc.getFontHeight(Graphics.FONT_SMALL);
        var lineHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var gap = (h * 0.024).toNumber();

        var bandHeight = bandBottom - bandTop;
        var candidates = [
            Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
            Graphics.FONT_NUMBER_MILD, Graphics.FONT_LARGE, Graphics.FONT_MEDIUM
        ];

        // Step the hero down until countdown + hero + label fit the band. If
        // even the smallest hero will not fit all three, the countdown digits
        // are what gives way -- the ring already carries remaining time.
        var showCountdown = true;
        var heroFont = fitHeroFont(dc, bandHeight, [countdownHeight, lineHeight], gap, candidates);
        if (dc.getFontHeight(heroFont) + countdownHeight + lineHeight + (gap * 2) > bandHeight) {
            showCountdown = false;
            heroFont = fitHeroFont(dc, bandHeight, [lineHeight], gap, candidates);
        }

        var heroHeight = dc.getFontHeight(heroFont);
        var rows;
        if (showCountdown) {
            rows = stackCenters(bandTop, bandBottom, [countdownHeight, heroHeight, lineHeight], gap);
            drawCenteredText(dc, cx, rows[0], Graphics.FONT_SMALL, formatCountdown(), C_MUTED);
        } else {
            rows = stackCenters(bandTop, bandBottom, [heroHeight, lineHeight], gap);
        }

        var heroY = showCountdown ? rows[1] : rows[0];
        var labelY = showCountdown ? rows[2] : rows[1];

        var hrText = (heartRate == null) ? "--" : heartRate.toString();
        drawCenteredText(dc, cx, heroY, heroFont, hrText, C_TEXT);

        var direction = slopeDirection(computeHrSlope());
        if (direction != 0) {
            var hrWidth = dc.getTextWidthInPixels(hrText, heroFont);
            drawTrendArrow(
                dc,
                cx + (hrWidth / 2) + (w * 0.055).toNumber(),
                heroY,
                (w * 0.028).toNumber(),
                direction,
                slopeColor(direction)
            );
        }

        drawCenteredText(dc, cx, labelY, Graphics.FONT_XTINY, "BPM", C_MUTED);

        drawActionButton(dc, w, h, "CANCEL", C_DANGER, C_TEXT);
    }

    // ---- DONE --------------------------------------------------------
    // Hero: average HR across the capture. The completed ring is drawn
    // solid in the result colour so "finished" reads from shape alone.
    //
    // NOTE: the risk score described in CLAUDE.md is not computed anywhere
    // reachable from this view yet. When it is, it belongs here as the hero
    // (a coloured badge / full ring: green low, amber moderate, red
    // elevated) and average HR drops to the secondary line below it.
    function drawDoneState(dc, w, h, cx, cy, radius, penWidth) as Void {
        drawTrack(dc, cx, cy, radius, penWidth);
        drawProgressArc(dc, cx, cy, radius, penWidth, 1.0, C_DONE);

        var bandTop = drawHeader(dc, w, h, "SCAN COMPLETE", C_DONE) + (h * 0.024).toNumber();
        var bandBottom = buttonRect(w, h)[1] - (h * 0.024).toNumber();

        var lineHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var gap = (h * 0.024).toNumber();

        var heroFont = fitHeroFont(
            dc, bandBottom - bandTop, [lineHeight, lineHeight], gap,
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD,
             Graphics.FONT_LARGE, Graphics.FONT_MEDIUM]
        );

        var rows = stackCenters(
            bandTop, bandBottom,
            [dc.getFontHeight(heroFont), lineHeight, lineHeight],
            gap
        );

        var average = averageHr();
        var averageText = (average == null) ? "--" : average.toString();

        drawCenteredText(dc, cx, rows[0], heroFont, averageText, C_TEXT);
        drawCenteredText(dc, cx, rows[1], Graphics.FONT_XTINY, "AVG BPM", C_MUTED);
        drawTrendRow(dc, w, rows[2], computeHrSlope());

        drawActionButton(dc, w, h, "AGAIN", C_DONE, C_BG);
    }

    // ==================================================================
    // Input support
    // ==================================================================

    function hitTestPrimaryAction(x, y) as Boolean {
        if (buttonBounds == null) {
            return false;
        }
        return x >= buttonBounds[0]
            && x <= buttonBounds[0] + buttonBounds[2]
            && y >= buttonBounds[1]
            && y <= buttonBounds[1] + buttonBounds[3];
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

    // The old version re-derived the button box from view.getWidth() /
    // view.getHeight(), which are Dc methods, not View methods. The view now
    // caches the box it actually drew, so the hit area can never drift from
    // the button.
    function onTap(clickEvent) {
        var coordinates = clickEvent.getCoordinates();
        if (view.hitTestPrimaryAction(coordinates[0], coordinates[1])) {
            view.handlePrimaryAction();
            return true;
        }
        return false;
    }
}
