import Toybox.ActivityMonitor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class glucoguardView extends WatchUi.View {

    // ------------------------------------------------------------------
    // Capture configuration (unchanged)
    // ------------------------------------------------------------------
    const SNAPSHOT_DURATION_SEC = 30; // kept at 30s for testing, per request -- not reverted
    const HR_BUFFER_INTERVAL_SEC = 4;
    const HR_BUFFER_MAX = 90;
    // Safety ceiling only -- a 4-minute snapshot produces ~240-500 beats,
    // so this should never realistically be hit. No FIFO eviction.
    const RR_BUFFER_MAX = 500;

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
    // Raw beat-to-beat intervals (ms) for the current snapshot only --
    // separate from hrBuffer, no RMSSD math applied here yet.
    var rrBuffer = [];
    // Recent-movement signal, read once at Start (not a stream). Both can
    // be null -- ActivityMonitor.Info fields are nullable on some devices.
    var moveBarAtStart = null;
    var stepsAtStart = null;
    // True while the cancel confirmation dialog is on top of this view --
    // onHide() checks this so pushing that dialog doesn't tear down the
    // in-progress capture underneath it.
    var confirmingCancel = false;

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
        // Pushing the cancel confirmation dialog also hides this view --
        // don't tear down the capture just because the dialog is on top;
        // only a confirmed cancel (cancelSnapshot(), called separately)
        // should do that.
        if (confirmingCancel) {
            return;
        }
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
        rrBuffer = [];
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensorData));
        // :period is required by registerSensorDataListener (max 4s) --
        // missing it throws "Missing :period field in options" and crashes
        // the app on the very first tap, before any capture starts.
        var rrOptions = {
            :period => 1,
            :heartBeatIntervals => { :enabled => true }
        };
        Sensor.registerSensorDataListener(method(:onRawSensorData), rrOptions);

        // Single one-shot read, not a stream -- no accelerometer, no
        // background work. ActivityMonitor.Info's fields are nullable on
        // some devices, so both are null-checked before use.
        var activityInfo = ActivityMonitor.getInfo();
        moveBarAtStart = activityInfo.moveBarLevel;
        stepsAtStart = activityInfo.steps;

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

    // Starting/restarting only -- cancelling always goes through
    // confirmCancelSnapshot() below instead (input delegate decides which
    // one to call). startSnapshot() already clears snapshotDone, so a plain
    // call works the same from READY or DONE.
    function handlePrimaryAction() as Void {
        startSnapshot();
    }

    // Tapping CANCEL asks first rather than cancelling immediately.
    // confirmingCancel keeps onHide() from stopping the capture just
    // because the dialog is now on top of this view. Custom-drawn (not
    // WatchUi.Confirmation) so it matches this app's own button styling
    // per UI-GUIDE.md instead of the system's plain text prompt.
    function confirmCancelSnapshot() as Void {
        confirmingCancel = true;
        var dialog = new glucoguardCancelConfirmView();
        WatchUi.pushView(dialog, new glucoguardCancelConfirmDelegate(self, dialog), WatchUi.SLIDE_IMMEDIATE);
    }

    // Called by glucoguardCancelConfirmDelegate once the user answers.
    function resolveCancelConfirm(confirmed as Boolean) as Void {
        confirmingCancel = false;
        if (confirmed) {
            cancelSnapshot();
        }
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

    // Raw beat-to-beat intervals for HRV, delivered separately from
    // onSensorData's periodic Sensor.Info. Buffers into rrBuffer for the
    // current snapshot -- no RMSSD math here yet.
    function onRawSensorData(sensorData as Sensor.SensorData) as Void {
        if (!snapshotActive) {
            return;
        }

        if (sensorData.heartRateData == null) {
            return;
        }

        var intervals = sensorData.heartRateData.heartBeatIntervals;
        if (intervals != null) {
            System.println("RR intervals (ms): " + intervals.toString());

            for (var i = 0; i < intervals.size(); i += 1) {
                if (rrBuffer.size() >= RR_BUFFER_MAX) {
                    break;
                }
                rrBuffer.add(intervals[i]);
            }
        }
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

    // RMSSD over the raw beat-to-beat buffer: root mean square of successive
    // differences. Needs at least 2 intervals to form one pair.
    function computeRmssd() {
        if (rrBuffer.size() < 2) {
            return null;
        }

        var pairCount = rrBuffer.size() - 1;
        var sumSquaredDiffs = 0.0;
        for (var i = 0; i < pairCount; i += 1) {
            var diff = rrBuffer[i + 1] - rrBuffer[i];
            sumSquaredDiffs += diff * diff;
        }

        return Math.sqrt(sumSquaredDiffs / pairCount);
    }

    function formatRmssd(rmssd) {
        if (rmssd == null) {
            return "HRV (RMSSD): -- ms";
        }
        return "HRV (RMSSD): " + rmssd.format("%.0f") + " ms";
    }

    // Garmin doesn't publish the exact time window moveBarLevel reflects, so
    // this is a coarse recently-active-vs-sedentary signal, not a precise
    // step count over a fixed window. 1 = recently active, 0 = sedentary/
    // unknown.
    function computeRecentlyActive() {
        return (moveBarAtStart != null && moveBarAtStart <= 1) ? 1 : 0;
    }

    // Display-only for now, for testing Step 8 -- no risk-score integration.
    // Kept short (not the longer "recently active"/"sedentary" wording) --
    // this row sits low in drawDoneState's band, where the circular screen
    // is narrower than at centre, so a long string here is what was
    // clipping into the ring.
    function formatMoveBar() {
        if (moveBarAtStart == null) {
            return "Move: --";
        }
        var label = (computeRecentlyActive() == 1) ? "active" : "still";
        return "Move: " + moveBarAtStart.toString() + " (" + label + ")";
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
        //
        // penWidth alone controls both "how thick" and "how large" the ring
        // reads as: outer edge = shorter/2 - edgePad, independent of
        // penWidth, so edgePad is what's actually near the true screen edge
        // (already ~2px, per UI-GUIDE.md's measured 193-of-195 finding) and
        // is deliberately left alone. Shrinking penWidth instead grows the
        // radius (the ring's centreline) while the outer edge stays fixed,
        // which is what makes it read as thinner and a size larger, and
        // frees up interior width for content.
        var shorter = (w < h) ? w : h;
        var penWidth = (w * 0.028).toNumber();
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
        var bandHeight = bandBottom - bandTop;

        var lineHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var gap = (h * 0.024).toNumber();
        var candidates = [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD,
                           Graphics.FONT_LARGE, Graphics.FONT_MEDIUM];

        // Same overflow escape hatch drawCapturingState uses for its countdown
        // row. fitHeroFont's own fallback just returns the smallest candidate
        // even when it doesn't fit, so with 5 rows to stack (hero + AVG BPM +
        // trend + RMSSD + move bar) this band can run out of room with no
        // warning -- the last row lands under the button and gets silently
        // painted over, since the button is drawn last. Drop the trend row
        // when that happens (it only repeats what was already shown live
        // during capture) so RMSSD and the move-bar debug line -- Step 7 and
        // 8's actual deliverables -- always have room.
        var showTrend = true;
        var heroFont = fitHeroFont(dc, bandHeight, [lineHeight, lineHeight, lineHeight, lineHeight], gap, candidates);
        if (dc.getFontHeight(heroFont) + (lineHeight * 4) + (gap * 4) > bandHeight) {
            showTrend = false;
            heroFont = fitHeroFont(dc, bandHeight, [lineHeight, lineHeight, lineHeight], gap, candidates);
        }

        var rows;
        if (showTrend) {
            rows = stackCenters(
                bandTop, bandBottom,
                [dc.getFontHeight(heroFont), lineHeight, lineHeight, lineHeight, lineHeight],
                gap
            );
        } else {
            rows = stackCenters(
                bandTop, bandBottom,
                [dc.getFontHeight(heroFont), lineHeight, lineHeight, lineHeight],
                gap
            );
        }

        var average = averageHr();
        var averageText = (average == null) ? "--" : average.toString();
        var rmssdText = formatRmssd(computeRmssd());
        var moveBarText = formatMoveBar();

        drawCenteredText(dc, cx, rows[0], heroFont, averageText, C_TEXT);
        drawCenteredText(dc, cx, rows[1], Graphics.FONT_XTINY, "AVG BPM", C_MUTED);
        if (showTrend) {
            drawTrendRow(dc, w, rows[2], computeHrSlope());
            drawCenteredText(dc, cx, rows[3], Graphics.FONT_XTINY, rmssdText, C_MUTED);
            drawCenteredText(dc, cx, rows[4], Graphics.FONT_XTINY, moveBarText, C_MUTED);
        } else {
            drawCenteredText(dc, cx, rows[2], Graphics.FONT_XTINY, rmssdText, C_MUTED);
            drawCenteredText(dc, cx, rows[3], Graphics.FONT_XTINY, moveBarText, C_MUTED);
        }

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

    // BehaviorDelegate dispatch rule (Toybox.WatchUi.BehaviorDelegate docs):
    // a tap is offered to onSelect() first, and if onSelect() returns true,
    // the matching InputDelegate.onTap() for that same tap is never called
    // at all. That's why an unconditional onSelect() that always returned
    // true made onTap()'s button hit-testing dead code below -- it never
    // ran, for any tap, ever.
    //
    // So: while not active, onSelect() handles the tap itself and returns
    // true -- this is "press anywhere to start", unchanged from before.
    // While active, onSelect() returns false instead, declining to consume
    // the tap so it falls through to onTap(), which has real coordinates
    // and can require a precise hit on CANCEL before anything happens.
    function onSelect() {
        if (view.snapshotActive) {
            return false;
        }
        view.handlePrimaryAction();
        return true;
    }

    // Only reachable for a tap while a snapshot is active (see onSelect()
    // above) -- a precise hit on CANCEL asks for confirmation instead of
    // cancelling immediately; anywhere else is ignored.
    function onTap(clickEvent) {
        var coordinates = clickEvent.getCoordinates();
        if (!view.hitTestPrimaryAction(coordinates[0], coordinates[1])) {
            return false;
        }
        view.confirmCancelSnapshot();
        return true;
    }
}

// Custom-drawn cancel-confirmation screen, styled like the rest of the app
// (pill buttons, palette colours by consequence) instead of the system's
// plain-text WatchUi.Confirmation. No ring/header -- this is a standalone
// prompt, not one of the three capture states.
class glucoguardCancelConfirmView extends WatchUi.View {

    // Monkey C doesn't allow reaching into another class's const across
    // files/classes (ClassName.CONST is not valid here), so this mirrors
    // the handful of glucoguardView palette values this screen needs.
    const C_BG     = 0x000000;
    const C_TEXT   = 0xFFFFFF;
    const C_LIVE   = 0x1E9BE9;
    const C_DANGER = 0xE03131;

    var resumeBounds = null;
    var cancelBounds = null;

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc) as Void {
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.setColor(C_TEXT, C_BG);
        dc.clear();

        dc.setColor(C_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx, (h * 0.30).toNumber(), Graphics.FONT_MEDIUM, "Cancel scan?",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var pillW = (w * 0.62).toNumber();
        var pillH = (h * 0.115).toNumber();
        var gap = (h * 0.03).toNumber();
        var y1 = (h * 0.52).toNumber();
        var y2 = y1 + pillH + gap;

        // Safe choice first/above -- resuming the capture, coloured like the
        // live-capture ring so it reads as "keep going". Destructive choice
        // below in C_DANGER, same red as the CANCEL button that led here.
        resumeBounds = drawPill(dc, cx, y1, pillW, pillH, "RESUME", C_LIVE, C_BG);
        cancelBounds = drawPill(dc, cx, y2, pillW, pillH, "CANCEL", C_DANGER, C_TEXT);
    }

    // Mirrors glucoguardView.drawActionButton()'s pill shape (radius =
    // height / 2) so this screen matches the rest of the app. Returns the
    // drawn rect for hit-testing since this view has two buttons, not one.
    function drawPill(dc, cx, centerY, w, h, label, fillColor, labelColor) {
        var x = cx - (w / 2);
        var y = centerY - (h / 2);

        dc.setColor(fillColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, w, h, h / 2);

        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx, centerY, Graphics.FONT_SMALL, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        return [x, y, w, h];
    }

    function hitTest(bounds, x, y) as Boolean {
        if (bounds == null) {
            return false;
        }
        return x >= bounds[0] && x <= bounds[0] + bounds[2]
            && y >= bounds[1] && y <= bounds[1] + bounds[3];
    }
}

// Only reached from a precise tap on CANCEL on the main view (see onTap
// above) -- hit-tests the two pill buttons drawn by glucoguardCancelConfirmView
// and tells the main view whether to actually cancel.
class glucoguardCancelConfirmDelegate extends WatchUi.InputDelegate {

    var view;
    var dialog;

    function initialize(viewToControl, dialogView) {
        InputDelegate.initialize();
        view = viewToControl;
        dialog = dialogView;
    }

    function onTap(clickEvent) {
        var coordinates = clickEvent.getCoordinates();
        var x = coordinates[0];
        var y = coordinates[1];

        if (dialog.hitTest(dialog.resumeBounds, x, y)) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            view.resolveCancelConfirm(false);
            return true;
        }
        if (dialog.hitTest(dialog.cancelBounds, x, y)) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            view.resolveCancelConfirm(true);
            return true;
        }
        return false;
    }
}
