import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Zone ramp shared by heart rate (Z1-Z5) and power (Z1-Z7): a colour means
// the same effort wherever it appears. Z6/Z7 just go deeper red.
const ZONE_BG = [0xA9B4BE, 0x5AA9E6, 0x5FC26A, 0xF7A23B, 0xEF5350, 0xD0342A, 0x9E2018] as Array<Number>;
const ZONE_FG = [0x101418, 0x08243A, 0x0C2E12, 0x3A1E00, 0x3A0000, 0xFFE8E5, 0xFFE0DC] as Array<Number>;

const DEG_TO_RAD = 0.017453293;
const RAD_TO_DEG = 57.29577951;

class CleanNavigationView extends WatchUi.DataField {

    // live values (null = no data yet)
    hidden var mSpd as Float?;
    hidden var mAvgSpd as Float?;
    hidden var mMaxSpd as Float?;
    hidden var mHr as Number?;
    hidden var mAvgHr as Number?;
    hidden var mHrZone as Number?;      // 1..5
    hidden var mPwr as Number?;
    hidden var mAvgPwr as Number?;
    hidden var mPwrZone as Number?;     // 1..7
    hidden var mWindKmh as Number?;
    hidden var mWindRelDeg as Number?;  // where the wind pushes you, relative to heading

    // fallback average power accumulation (only while the timer runs)
    hidden var mPwrSum as Number;
    hidden var mPwrCnt as Number;

    hidden var mHrZones as Array<Number>?;

    // palette, refreshed each onUpdate from the Edge day/night background
    hidden var mDark as Boolean;
    hidden var cBg as Number;
    hidden var cFg as Number;
    hidden var cSub as Number;
    hidden var cDiv as Number;
    hidden var cTop as Number;
    hidden var cPanel as Number;

    function initialize() {
        DataField.initialize();
        mPwrSum = 0;
        mPwrCnt = 0;
        mDark = false;
        cBg = 0xFFFFFF;
        cFg = 0x101418;
        cSub = 0x6B7681;
        cDiv = 0xD5DBE0;
        cTop = 0x101418;
        cPanel = 0xEEF1F3;
        mHrZones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_BIKING);
    }

    function onLayout(dc as Dc) as Void {
    }

    function compute(info as Activity.Info) as Void {
        mSpd = (info.currentSpeed != null) ? info.currentSpeed * 3.6 : null;
        mAvgSpd = (info.averageSpeed != null) ? info.averageSpeed * 3.6 : null;
        mMaxSpd = (info.maxSpeed != null) ? info.maxSpeed * 3.6 : null;

        mHr = info.currentHeartRate;
        mAvgHr = info.averageHeartRate;
        mHrZone = (mHr != null) ? hrZoneFor(mHr as Number) : null;

        mPwr = (info has :currentPower) ? info.currentPower : null;
        var avgP = (info has :averagePower) ? info.averagePower : null;
        if (avgP != null) {
            mAvgPwr = avgP;
        } else if (mPwr != null) {
            var running = true;
            if (info has :timerState && info.timerState != null) {
                running = info.timerState == Activity.TIMER_STATE_ON;
            }
            if (running) {
                mPwrSum += mPwr as Number;
                mPwrCnt += 1;
            }
            mAvgPwr = (mPwrCnt > 0) ? mPwrSum / mPwrCnt : null;
        }
        mPwrZone = (mPwr != null) ? pwrZoneFor(mPwr as Number) : null;

        computeWind(info);
    }

    hidden function computeWind(info as Activity.Info) as Void {
        if (!(Toybox has :Weather)) {
            return;
        }
        var cc = Toybox.Weather.getCurrentConditions();
        if (cc == null) {
            return;
        }
        if (cc.windSpeed != null) {
            mWindKmh = (cc.windSpeed * 3.6 + 0.5).toNumber();
        }
        if (cc.windBearing != null) {
            var headDeg = 0.0;
            if (info.currentHeading != null) {
                headDeg = info.currentHeading * RAD_TO_DEG;
            }
            // windBearing is where the wind comes FROM; +180 = where it pushes you
            var rel = cc.windBearing.toFloat() + 180.0 - headDeg;
            mWindRelDeg = ((rel.toNumber() % 360) + 360) % 360;
        }
    }

    hidden function hrZoneFor(hr as Number) as Number {
        var zones = mHrZones;
        if (zones == null || zones.size() < 6) {
            return 1;
        }
        for (var z = 1; z <= 4; z++) {
            if (hr <= zones[z]) {
                return z;
            }
        }
        return 5;
    }

    hidden function pwrZoneFor(pwr as Number) as Number {
        var ftp = 250;
        var v = null;
        try {
            v = Application.Properties.getValue("ftp");
        } catch (e) {
            v = null;
        }
        if (v != null && v instanceof Number && v > 0) {
            ftp = v;
        }
        // Coggan split, percent of FTP
        var pct = pwr * 100.0 / ftp;
        if (pct <= 55) { return 1; }
        if (pct <= 75) { return 2; }
        if (pct <= 90) { return 3; }
        if (pct <= 105) { return 4; }
        if (pct <= 120) { return 5; }
        if (pct <= 150) { return 6; }
        return 7;
    }

    // wind colour trio [bg, fg] by how much the wind costs you
    hidden function windColors() as Array<Number> {
        if (mWindRelDeg == null) {
            return [cPanel, cSub];
        }
        var deg = mWindRelDeg as Number;
        var off = (deg > 180) ? 360 - deg : deg;
        if (off <= 45) { return [ZONE_BG[2], ZONE_FG[2]]; }   // tailwind, green
        if (off >= 135) { return [ZONE_BG[4], ZONE_FG[4]]; }  // headwind, red
        return [ZONE_BG[3], ZONE_FG[3]];                      // crosswind, orange
    }

    function onUpdate(dc as Dc) as Void {
        mDark = getBackgroundColor() == Graphics.COLOR_BLACK;
        if (mDark) {
            cBg = 0x0B0E11;
            cFg = 0xF4F6F8;
            cSub = 0x8B97A2;
            cDiv = 0x2A3138;
            cTop = 0x4FC8E8;
            cPanel = 0x14181D;
        } else {
            cBg = 0xFFFFFF;
            cFg = 0x101418;
            cSub = 0x6B7681;
            cDiv = 0xD5DBE0;
            cTop = 0x101418;
            cPanel = 0xEEF1F3;
        }

        dc.setColor(Graphics.COLOR_TRANSPARENT, cBg);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        // top accent border, then the strip itself
        dc.setColor(cTop, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, w, 2);

        if (h >= 175) {
            drawTall(dc, w, h);
        } else {
            drawSlim(dc, w, h);
        }
    }

    // ================= tall strip: wind tile + speed / HR + power =================

    hidden function drawTall(dc as Dc, w as Number, h as Number) as Void {
        var y0 = 2;
        var row1H = ((h - y0) * 0.54).toNumber();
        var row2Y = y0 + row1H + 2;
        var row2H = h - row2Y;

        // ---- row 1: wind tile ----
        var windW = (w * 0.25).toNumber();
        var wc = windColors();
        dc.setColor(wc[0], Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y0, windW, row1H);
        var arrowSize = row1H * 0.42;
        drawWindArrow(dc, windW / 2, y0 + row1H * 0.40, arrowSize, wc[1]);
        var windTxt = (mWindKmh != null) ? (mWindKmh as Number).toString() : "--";
        drawValueUnitCenter(dc, windW / 2, (y0 + row1H * 0.82).toNumber(), windTxt,
            Graphics.FONT_SMALL, "km/h", Graphics.FONT_XTINY, wc[1], wc[1]);

        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(windW, y0, 2, row1H);

        // ---- row 1: avg/max column on the right ----
        var colW = (w * 0.21).toNumber();
        var colX = w - colW;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(colX - 2, y0 + 8, 2, row1H - 16);

        var glyphX = colX + 12;
        var avgY = y0 + (row1H * 0.32).toNumber();
        var maxY = y0 + (row1H * 0.68).toNumber();
        drawAvgGlyph(dc, glyphX, avgY, 7, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(glyphX + 14, avgY, Graphics.FONT_SMALL, fmt1(mAvgSpd),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawMaxGlyph(dc, glyphX, maxY, 7, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(glyphX + 14, maxY, Graphics.FONT_SMALL, fmt1(mMaxSpd),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // ---- row 1: current speed, big ----
        var spdTxt = fmt1(mSpd);
        var maxWidth = colX - 2 - (windW + 2) - 60;
        var spdFont = pickFont(dc, spdTxt, maxWidth,
            [Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        drawValueUnitRight(dc, colX - 14, y0 + row1H / 2, spdTxt, spdFont, "km/h",
            Graphics.FONT_XTINY, cFg, cSub);

        // ---- row separator ----
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y0 + row1H, w, 2);

        // ---- row 2: heart rate + power blocks ----
        var hrW = (w * 0.5).toNumber() - 1;
        drawZoneBlock(dc, 0, row2Y, hrW, row2H, true);
        dc.setColor(cTop, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(hrW, row2Y, 2, row2H);
        drawZoneBlock(dc, hrW + 2, row2Y, w - hrW - 2, row2H, false);
    }

    // one filled block of row 2: icon + current on the left, zone + avg on the right
    hidden function drawZoneBlock(dc as Dc, x as Number, y as Number, bw as Number, bh as Number, isHr as Boolean) as Void {
        var zone = isHr ? mHrZone : mPwrZone;
        var cur = isHr ? mHr : mPwr;
        var avg = isHr ? mAvgHr : mAvgPwr;

        var bg = cPanel;
        var fg = cSub;
        if (zone != null) {
            bg = ZONE_BG[zone - 1];
            fg = ZONE_FG[zone - 1];
        }
        dc.setColor(bg, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, bw, bh);

        var cy = y + bh / 2;
        var pad = 12;
        var iconS = bh * 0.24;
        if (isHr) {
            drawHeart(dc, x + pad + iconS / 2, cy, iconS, fg);
        } else {
            drawBolt(dc, x + pad + iconS / 2, cy, iconS * 1.1, fg);
        }
        var curTxt = (cur != null) ? (cur as Number).toString() : "--";
        var vFont = pickFont(dc, curTxt, bw * 0.48,
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + pad + iconS + 8, cy, vFont, curTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var rx = x + bw - pad;
        if (zone != null) {
            dc.drawText(rx, y + (bh * 0.30).toNumber(), Graphics.FONT_TINY, "Z" + zone,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        var avgTxt = (avg != null) ? (avg as Number).toString() : "--";
        var avgY = y + (bh * 0.68).toNumber();
        dc.drawText(rx, avgY, Graphics.FONT_SMALL, avgTxt,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        var avgW = dc.getTextWidthInPixels(avgTxt, Graphics.FONT_SMALL);
        drawAvgGlyph(dc, rx - avgW - 12, avgY, 6, fg);
    }

    // ================= slim strip: four tiles in a row =================

    hidden function drawSlim(dc as Dc, w as Number, h as Number) as Void {
        var y0 = 2;
        var bh = h - y0;
        var inner = w - 6; // three 2px dividers
        var w0 = (inner * 0.214).toNumber();
        var w1 = (inner * 0.286).toNumber();
        var w2 = (inner * 0.25).toNumber();
        var w3 = inner - w0 - w1 - w2;

        var x = 0;
        drawSlimWind(dc, x, y0, w0, bh);
        x += w0;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y0, 2, bh);
        x += 2;
        drawSlimSpeed(dc, x, y0, w1, bh);
        x += w1;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y0, 2, bh);
        x += 2;
        drawSlimZone(dc, x, y0, w2, bh, true);
        x += w2;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y0, 2, bh);
        x += 2;
        drawSlimZone(dc, x, y0, w3, bh, false);
    }

    hidden function drawSlimWind(dc as Dc, x as Number, y as Number, bw as Number, bh as Number) as Void {
        var wc = windColors();
        var tint = (mWindRelDeg != null) ? wc[0] : cSub;
        var cx = x + bw / 2;
        drawWindArrow(dc, cx, y + (bh * 0.36).toNumber(), bh * 0.34, tint);
        var windTxt = (mWindKmh != null) ? (mWindKmh as Number).toString() : "--";
        drawValueUnitCenter(dc, cx, y + (bh * 0.78).toNumber(), windTxt,
            Graphics.FONT_NUMBER_MILD, "km/h", Graphics.FONT_XTINY, cFg, cSub);
    }

    hidden function drawSlimSpeed(dc as Dc, x as Number, y as Number, bw as Number, bh as Number) as Void {
        var cx = x + bw / 2;
        var spdTxt = fmt1(mSpd);
        var vFont = pickFont(dc, spdTxt, bw * 0.72,
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        drawValueUnitCenter(dc, cx, y + (bh * 0.34).toNumber(), spdTxt, vFont,
            "km/h", Graphics.FONT_XTINY, cFg, cSub);

        // avg + max side by side
        var subY = y + (bh * 0.78).toNumber();
        var avgTxt = fmt1(mAvgSpd);
        var maxTxt = fmt1(mMaxSpd);
        var f = Graphics.FONT_XTINY;
        var aw = dc.getTextWidthInPixels(avgTxt, f);
        var mw = dc.getTextWidthInPixels(maxTxt, f);
        var total = 12 + 4 + aw + 14 + 10 + 4 + mw;
        var sx = cx - total / 2;
        drawAvgGlyph(dc, sx + 6, subY, 5, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sx + 16, subY, f, avgTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawMaxGlyph(dc, sx + 16 + aw + 14 + 5, subY, 5, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sx + 16 + aw + 14 + 14, subY, f, maxTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    hidden function drawSlimZone(dc as Dc, x as Number, y as Number, bw as Number, bh as Number, isHr as Boolean) as Void {
        var zone = isHr ? mHrZone : mPwrZone;
        var cur = isHr ? mHr : mPwr;
        var avg = isHr ? mAvgHr : mAvgPwr;
        var zColor = (zone != null) ? ZONE_BG[zone - 1] : cSub;

        // zone shown as a thin edge bar so the strip stays quiet
        dc.setColor(zColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, 9, bh);

        var cx = x + 9 + (bw - 9) / 2;
        var topY = y + (bh * 0.34).toNumber();
        var curTxt = (cur != null) ? (cur as Number).toString() : "--";
        var vFont = pickFont(dc, curTxt, (bw - 9) * 0.62,
            [Graphics.FONT_NUMBER_MILD, Graphics.FONT_SMALL] as Array<FontDefinition>);
        var iconS = bh * 0.13;
        var vw = dc.getTextWidthInPixels(curTxt, vFont);
        var groupW = iconS + 6 + vw;
        var gx = cx - groupW / 2;
        if (isHr) {
            drawHeart(dc, gx + iconS / 2, topY, iconS, zColor);
        } else {
            drawBolt(dc, gx + iconS / 2, topY, iconS * 1.1, zColor);
        }
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(gx + iconS + 6, topY, vFont, curTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // zone label + average underneath
        var subY = y + (bh * 0.78).toNumber();
        var f = Graphics.FONT_XTINY;
        var zTxt = (zone != null) ? "Z" + zone : "";
        var avgTxt = (avg != null) ? (avg as Number).toString() : "--";
        var zw = dc.getTextWidthInPixels(zTxt, f);
        var aw = dc.getTextWidthInPixels(avgTxt, f);
        var total = zw + 10 + 12 + 4 + aw;
        var sx = cx - total / 2;
        if (zone != null) {
            dc.setColor(zColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(sx, subY, f, zTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        drawAvgGlyph(dc, sx + zw + 10 + 5, subY, 5, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sx + zw + 10 + 14, subY, f, avgTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ================= glyphs =================

    hidden function drawWindArrow(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, color as Number) as Void {
        var deg = (mWindRelDeg != null) ? (mWindRelDeg as Number).toFloat() : 0.0;
        var pts = [[12.0, 2.4], [20.0, 11.8], [15.4, 11.8], [15.4, 21.6],
                   [8.6, 21.6], [8.6, 11.8], [4.0, 11.8]];
        var rad = deg * DEG_TO_RAD;
        var c = Math.cos(rad);
        var s = Math.sin(rad);
        var k = size / 24.0;
        var out = new Array<Graphics.Point2D>[pts.size()];
        for (var i = 0; i < pts.size(); i++) {
            var dx = (pts[i][0] - 12.0) * k;
            var dy = (pts[i][1] - 12.0) * k;
            out[i] = [cx + dx * c - dy * s, cy + dx * s + dy * c] as Graphics.Point2D;
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(out);
    }

    hidden function drawHeart(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var r = size * 0.30;
        dc.fillCircle(cx - size * 0.22, cy - size * 0.16, r);
        dc.fillCircle(cx + size * 0.22, cy - size * 0.16, r);
        dc.fillPolygon([[cx - size * 0.50, cy - size * 0.02],
                        [cx + size * 0.50, cy - size * 0.02],
                        [cx, cy + size * 0.52]]);
    }

    hidden function drawBolt(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, color as Number) as Void {
        var pts = [[13.4, 1.8], [4.0, 13.9], [10.3, 13.9], [9.4, 22.2], [19.6, 9.6], [13.2, 9.6]];
        var k = size / 24.0;
        var out = new Array<Graphics.Point2D>[pts.size()];
        for (var i = 0; i < pts.size(); i++) {
            out[i] = [cx + (pts[i][0] - 12.0) * k, cy + (pts[i][1] - 12.0) * k] as Graphics.Point2D;
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(out);
    }

    hidden function drawAvgGlyph(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, r);
        dc.drawLine(cx - r, cy + r, cx + r, cy - r);
        dc.setPenWidth(1);
    }

    hidden function drawMaxGlyph(dc as Dc, cx as Numeric, cy as Numeric, s as Numeric, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx - s, cy + s * 0.7], [cx + s, cy + s * 0.7], [cx, cy - s * 0.8]]);
    }

    // ================= text helpers =================

    // "35,4" — decimal comma, as on the design
    hidden function fmt1(v as Float?) as String {
        if (v == null) {
            return "--";
        }
        var s = v.format("%.1f");
        var i = s.find(".");
        if (i != null) {
            s = s.substring(0, i) + "," + s.substring(i + 1, s.length());
        }
        return s;
    }

    hidden function pickFont(dc as Dc, text as String, maxW as Numeric, fonts as Array<FontDefinition>) as FontDefinition {
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getTextWidthInPixels(text, fonts[i]) <= maxW) {
                return fonts[i];
            }
        }
        return fonts[fonts.size() - 1];
    }

    hidden function drawValueUnitRight(dc as Dc, xRight as Numeric, yCenter as Numeric,
            val as String, vFont as FontDefinition, unit as String, uFont as FontDefinition,
            vColor as Number, uColor as Number) as Void {
        var uw = dc.getTextWidthInPixels(unit, uFont);
        dc.setColor(vColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xRight - uw - 6, yCenter, vFont, val,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        var vh = dc.getFontHeight(vFont);
        var uh = dc.getFontHeight(uFont);
        dc.setColor(uColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xRight, yCenter + (vh - uh) * 0.26, uFont, unit,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    hidden function drawValueUnitCenter(dc as Dc, xCenter as Numeric, yCenter as Numeric,
            val as String, vFont as FontDefinition, unit as String, uFont as FontDefinition,
            vColor as Number, uColor as Number) as Void {
        var vw = dc.getTextWidthInPixels(val, vFont);
        var uw = dc.getTextWidthInPixels(unit, uFont);
        var x = xCenter - (vw + 4 + uw) / 2;
        dc.setColor(vColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, yCenter, vFont, val,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var vh = dc.getFontHeight(vFont);
        var uh = dc.getFontHeight(uFont);
        dc.setColor(uColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + vw + 4, yCenter + (vh - uh) * 0.26, uFont, unit,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
