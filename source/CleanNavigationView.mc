import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
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

    // navigation (full-screen tier)
    hidden var mDistNext as Float?;     // metres to next course point
    hidden var mNextName as String?;
    hidden var mBearingRelDeg as Number?; // bearing to next point, relative to heading

    // grade, ride timer, distance
    hidden var mGrade as Float?;        // smoothed grade %, signed
    hidden var mLastAlt as Float?;
    hidden var mLastDist as Float?;
    hidden var mTimerSec as Number?;    // ride timer, seconds
    hidden var mElapsedKm as Float?;
    hidden var mAscent as Float?;       // total ascent, metres (D+)

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
        computeNavigation(info);
    }

    hidden function computeNavigation(info as Activity.Info) as Void {
        mDistNext = (info has :distanceToNextPoint) ? info.distanceToNextPoint : null;
        mNextName = (info has :nameOfNextPoint) ? info.nameOfNextPoint : null;

        mBearingRelDeg = null;
        if (info has :bearing && info.bearing != null) {
            var headDeg = 0.0;
            if (info.currentHeading != null) {
                headDeg = info.currentHeading * RAD_TO_DEG;
            }
            var rel = info.bearing * RAD_TO_DEG - headDeg;
            mBearingRelDeg = ((rel.toNumber() % 360) + 360) % 360;
        }

        mTimerSec = (info.timerTime != null) ? info.timerTime / 1000 : null;
        mElapsedKm = (info.elapsedDistance != null) ? info.elapsedDistance / 1000.0 : null;
        mAscent = (info has :totalAscent) ? info.totalAscent : null;

        // grade: altitude change over distance, EMA-smoothed, sampled every >=5 m
        if (info.altitude != null && info.elapsedDistance != null) {
            var alt = info.altitude as Float;
            var dist = info.elapsedDistance as Float;
            if (mLastAlt == null || mLastDist == null) {
                mLastAlt = alt;
                mLastDist = dist;
            } else {
                var dDist = dist - (mLastDist as Float);
                if (dDist >= 5.0) {
                    var raw = (alt - (mLastAlt as Float)) / dDist * 100.0;
                    if (raw > 35.0) { raw = 35.0; }
                    if (raw < -35.0) { raw = -35.0; }
                    mGrade = (mGrade == null) ? raw : (mGrade as Float) * 0.7 + raw * 0.3;
                    mLastAlt = alt;
                    mLastDist = dist;
                }
            }
        }
    }

    // grade colour: green descent, quiet flat, orange, red, deep red as it steepens
    hidden function gradeColor() as Number {
        if (mGrade == null) {
            return cSub;
        }
        var g = mGrade as Float;
        if (g <= -1.0) { return ZONE_BG[2]; }
        if (g < 2.0) { return cSub; }
        if (g < 5.0) { return ZONE_BG[3]; }
        if (g < 8.0) { return ZONE_BG[4]; }
        return ZONE_BG[5];
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

        // the three designs are all full-width; a half-width slot can't hold them
        if (w < 400) {
            dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - dc.getFontHeight(Graphics.FONT_XTINY) * 0.6,
                Graphics.FONT_XTINY, "CleanNav",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(w / 2, h / 2 + dc.getFontHeight(Graphics.FONT_XTINY) * 0.6,
                Graphics.FONT_XTINY, "full-width only",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        if (h >= 600) {
            // full screen only: design B stack — a half-screen slot gets the
            // medium strip instead of a squeezed version of this
            drawFull(dc, w, h);
            return;
        }

        // strip tiers get the accent top border
        dc.setColor(cTop, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, w, 2);

        if (h >= 175) {
            drawTall(dc, w, h);
        } else {
            drawSlim(dc, w, h);
        }
    }

    // ================= full screen: design B — nav / speed / wind / HR / power / footer =================

    // Coordinator only: each row draws in its own helper that RETURNS before the
    // next row starts. The on-device call stack is tiny — a big frame under a
    // glyph call overflows it (it did), so no row work may live in this frame.
    hidden function drawFull(dc as Dc, w as Number, h as Number) as Void {
        var s = h / 800.0;
        var pad = (16 * s).toNumber() + 2;
        if (pad < 16) { pad = 16; }
        var r1H = (244 * s).toNumber();
        var r2H = (150 * s).toNumber();
        var r3H = (124 * s).toNumber();
        var r4H = (122 * s).toNumber();
        var r5H = (122 * s).toNumber();

        drawFullNav(dc, w, r1H, (54 * s).toNumber(), pad, s);

        var y = r1H;
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, 3);
        y += 3;
        drawFullSpeed(dc, y, w, r2H, pad, s);
        y += r2H;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, 2);
        y += 2;
        drawFullWind(dc, y, w, r3H, pad, s);
        y += r3H;
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, 2);
        y += 2;
        drawFullZoneRow(dc, y, w, r4H, true);
        y += r4H;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, 2);
        y += 2;
        drawFullZoneRow(dc, y, w, r5H, false);
        y += r5H;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, 2);
        y += 2;
        drawFullFooter(dc, y, w, h - y, pad);
    }

    // nav row: bearing pointer + distance + next-point name, grade / D+ / elapsed below
    hidden function drawFullNav(dc as Dc, w as Number, r1H as Number, subH as Number, pad as Number, s as Float) as Void {
        var mainH = r1H - subH;
        var arrowS = 118 * s;
        drawNavArrow(dc, pad + arrowS / 2, mainH / 2, arrowS, cFg);

        var distTxt = "--";
        var distUnit = "m";
        if (mDistNext != null) {
            var dn = mDistNext as Float;
            if (dn < 1000) {
                distTxt = dn.toNumber().toString();
            } else {
                distTxt = fmt1(dn / 1000.0);
                distUnit = "km";
            }
        }
        var maxVW = w - pad * 2 - arrowS - 20;
        var dFont = pickFontH(dc, distTxt, maxVW, mainH * 0.62,
            [Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        drawValueUnitRight(dc, w - pad, (mainH * 0.38).toNumber(), distTxt, dFont,
            distUnit, Graphics.FONT_TINY, cFg, cSub);
        if (mNextName != null && !(mNextName as String).equals("")) {
            var nm = truncate(dc, mNextName as String, Graphics.FONT_TINY, maxVW);
            dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - pad, (mainH * 0.80).toNumber(), Graphics.FONT_TINY, nm,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // sub-row: current grade + time elapsed since the ride started
        var subY = mainH;
        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, subY, w, 2);
        var subC = subY + 2 + (subH - 2) / 2;
        var gc = gradeColor();
        var gradeUp = (mGrade != null) ? (mGrade as Float) >= 0.0 : true;
        drawGradeArrow(dc, pad + 9, subC, 10 * s + 6, gradeUp, gc);
        var gTxt = "-- %";
        if (mGrade != null) {
            var g = mGrade as Float;
            gTxt = fmt1(g < 0.0 ? -g : g) + " %";
        }
        dc.setColor(gc, Graphics.COLOR_TRANSPARENT);
        dc.drawText(pad + 28, subC, Graphics.FONT_SMALL, gTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        // total ascent (D+), centred between grade and elapsed time
        var ascTxt = (mAscent != null) ? (mAscent as Float).toNumber().toString() : "--";
        var ascW = dc.getTextWidthInPixels(ascTxt, Graphics.FONT_SMALL);
        var ascX = w / 2 - (18 + 6 + ascW) / 2;
        drawMountain(dc, ascX + 9, subC, 18, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(ascX + 24, subC, Graphics.FONT_SMALL, ascTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
        dc.drawText(ascX + 24 + ascW + 4, subC + 3, Graphics.FONT_XTINY, "m",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var elTxt = (mTimerSec != null) ? fmtHMS(mTimerSec as Number) : "-:--:--";
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - pad, subC, Graphics.FONT_SMALL, elTxt,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        var elW = dc.getTextWidthInPixels(elTxt, Graphics.FONT_SMALL);
        drawClock(dc, w - pad - elW - 16, subC, 9 * s + 4, cSub);
    }

    // speed row: avg/max column left, current big right
    hidden function drawFullSpeed(dc as Dc, y as Number, w as Number, r2H as Number, pad as Number, s as Float) as Void {
        var avgY = y + (r2H * 0.30).toNumber();
        var maxY = y + (r2H * 0.70).toNumber();
        drawAvgGlyph(dc, pad + 8, avgY, 8, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(pad + 24, avgY, Graphics.FONT_SMALL, fmt1(mAvgSpd),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawMaxGlyph(dc, pad + 8, maxY, 8, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(pad + 24, maxY, Graphics.FONT_SMALL, fmt1(mMaxSpd),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var spdTxt = fmt1(mSpd);
        var sFont = pickFontH(dc, spdTxt, w - pad * 2 - (110 * s).toNumber() - 40, r2H,
            [Graphics.FONT_NUMBER_THAI_HOT, Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM] as Array<FontDefinition>);
        drawValueUnitRight(dc, w - pad, y + r2H / 2, spdTxt, sFont, "km/h",
            Graphics.FONT_TINY, cFg, cSub);
    }

    // wind row on its cost colour
    hidden function drawFullWind(dc as Dc, y as Number, w as Number, r3H as Number, pad as Number, s as Float) as Void {
        var wc = windColors();
        dc.setColor(wc[0], Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, r3H);
        var wArrowS = 76 * s;
        drawWindArrow(dc, pad + wArrowS / 2, y + r3H / 2, wArrowS, wc[1]);
        dc.setColor(wc[1], Graphics.COLOR_TRANSPARENT);
        dc.drawText(pad + wArrowS + 16, y + r3H / 2, Graphics.FONT_SMALL, windLabel(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var windTxt = (mWindKmh != null) ? (mWindKmh as Number).toString() : "--";
        var wFont = pickFontH(dc, windTxt, w * 0.3, r3H * 0.85,
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        drawValueUnitRight(dc, w - pad, y + r3H / 2, windTxt, wFont, "km/h",
            Graphics.FONT_XTINY, wc[1], wc[1]);
    }

    // footer: clock / distance ridden / battery
    hidden function drawFullFooter(dc as Dc, y as Number, w as Number, fH as Number, pad as Number) as Void {
        if (fH <= 8) {
            return;
        }
        dc.setColor(cPanel, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, fH);
        var fy = y + fH / 2;
        dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
        var clock = System.getClockTime();
        dc.drawText(pad, fy, Graphics.FONT_XTINY,
            clock.hour.format("%d") + ":" + clock.min.format("%02d"),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var kmTxt = (mElapsedKm != null) ? fmt1(mElapsedKm) + " km" : "-- km";
        dc.drawText(w / 2, fy, Graphics.FONT_XTINY, kmTxt,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        var stats = System.getSystemStats();
        if (stats != null && stats.battery != null) {
            dc.drawText(w - pad, fy, Graphics.FONT_XTINY, stats.battery.toNumber().toString() + " %",
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // one full-width zone row of design B: icon + current left, zone + avg right
    hidden function drawFullZoneRow(dc as Dc, y as Number, w as Number, rh as Number, isHr as Boolean) as Void {
        var zone = isHr ? mHrZone : mPwrZone;
        var cur = isHr ? mHr : mPwr;
        var avg = isHr ? mAvgHr : mAvgPwr;
        var pad = 18;
        var x = 0;
        var fg = cFg;
        var sub = cSub;

        if (isHr) {
            // full zone fill
            var bg = cPanel;
            if (zone != null) {
                bg = ZONE_BG[zone - 1];
                fg = ZONE_FG[zone - 1];
                sub = fg;
            }
            dc.setColor(bg, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, y, w, rh);
        } else if (zone != null) {
            // zone as an edge bar, quiet row
            dc.setColor(ZONE_BG[zone - 1], Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, y, (14 * rh / 122.0).toNumber() + 2, rh);
            x = (14 * rh / 122.0).toNumber() + 2;
        }

        var cy = y + rh / 2;
        var iconS = rh * 0.26;
        if (isHr) {
            drawHeart(dc, x + pad + iconS / 2, cy, iconS, fg);
        } else {
            drawBolt(dc, x + pad + iconS / 2, cy, iconS * 1.1, fg);
        }
        var curTxt = (cur != null) ? (cur as Number).toString() : "--";
        var vFont = pickFontH(dc, curTxt, w * 0.45, rh * 0.9,
            [Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var vx = x + pad + iconS + 10;
        dc.drawText(vx, cy, vFont, curTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var vw = dc.getTextWidthInPixels(curTxt, vFont);
        dc.setColor(sub, Graphics.COLOR_TRANSPARENT);
        dc.drawText(vx + vw + 8, cy + rh * 0.12, Graphics.FONT_TINY, isHr ? "bpm" : "W",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var rx = w - pad;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        if (zone != null) {
            dc.drawText(rx, y + (rh * 0.28).toNumber(), Graphics.FONT_TINY, "Z" + zone,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        var avgTxt = (avg != null) ? (avg as Number).toString() : "--";
        var avgY = y + (rh * 0.70).toNumber();
        dc.drawText(rx, avgY, Graphics.FONT_SMALL, avgTxt,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        var avgW = dc.getTextWidthInPixels(avgTxt, Graphics.FONT_SMALL);
        drawAvgGlyph(dc, rx - avgW - 14, avgY, 7, sub);
    }

    // ================= tall strip: wind tile + speed / HR + power =================

    // Coordinator only: row-1 tiles draw in helpers that RETURN before the next
    // runs — the on-device call stack is tiny, no big frame may sit under a glyph.
    hidden function drawTall(dc as Dc, w as Number, h as Number) as Void {
        var y0 = 2;
        var row1H = ((h - y0) * 0.54).toNumber();
        // half-screen and larger slots: step the whole strip up one type tier
        var big = row1H >= 150;
        var windW = (w * 0.25).toNumber();
        var colX = w - (w * 0.22).toNumber();

        drawTallWindGrade(dc, y0, windW, row1H, big);
        drawTallKmTile(dc, y0, colX, w - colX, row1H, big);
        drawTallSpeed(dc, y0, windW, colX, row1H, big);

        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(windW, y0, 2, row1H);
        dc.fillRectangle(colX - 2, y0, 2, row1H);
        dc.fillRectangle(0, y0 + row1H, w, 2);

        var row2Y = y0 + row1H + 2;
        var hrW = (w * 0.5).toNumber() - 1;
        drawZoneBlock(dc, 0, row2Y, hrW, h - row2Y, true);
        dc.setColor(cTop, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(hrW, row2Y, 2, h - row2Y);
        drawZoneBlock(dc, hrW + 2, row2Y, w - hrW - 2, h - row2Y, false);
    }

    // row 1 left tile, split in two: wind on top, grade below
    hidden function drawTallWindGrade(dc as Dc, y0 as Number, windW as Number, row1H as Number, big as Boolean) as Void {
        var vF = big ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL;
        var uF = big ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var halfH = row1H / 2;
        var wc = windColors();
        dc.setColor(wc[0], Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y0, windW, halfH);
        var wCy = y0 + halfH / 2;
        var windTxt = (mWindKmh != null) ? (mWindKmh as Number).toString() : "--";
        var wMax = windW - 12;
        var wVF = vF;
        var wUF = uF;
        var aS = halfH * 0.58;
        var wVW = dc.getTextWidthInPixels(windTxt, wVF);
        var wUW = dc.getTextWidthInPixels("km/h", wUF);
        var wTotal = aS + 8 + wVW + 4 + wUW;
        // fit order: smaller fonts first, then shrink the arrow, then drop the unit
        if (wTotal > wMax && big) {
            wVF = Graphics.FONT_SMALL;
            wUF = Graphics.FONT_XTINY;
            wVW = dc.getTextWidthInPixels(windTxt, wVF);
            wUW = dc.getTextWidthInPixels("km/h", wUF);
            wTotal = aS + 8 + wVW + 4 + wUW;
        }
        if (wTotal > wMax) {
            aS = aS - (wTotal - wMax);
            if (aS < halfH * 0.30) { aS = halfH * 0.30; }
            wTotal = aS + 8 + wVW + 4 + wUW;
        }
        if (wTotal <= wMax) {
            var wx = (windW - wTotal) / 2;
            drawWindArrow(dc, wx + aS / 2, wCy, aS, wc[1]);
            dc.setColor(wc[1], Graphics.COLOR_TRANSPARENT);
            dc.drawText(wx + aS + 8, wCy, wVF, windTxt,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(wx + aS + 8 + wVW + 4,
                wCy + (dc.getFontHeight(wVF) - dc.getFontHeight(wUF)) * 0.26, wUF, "km/h",
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            // no room for the text: drop it entirely — just the arrow,
            // centred in the cell and given the freed space
            var aOnly = halfH * 0.66;
            if (aOnly > windW * 0.55) { aOnly = windW * 0.55; }
            drawWindArrow(dc, windW / 2, wCy, aOnly, wc[1]);
        }

        var gc = gradeColor();
        var gradeUp = (mGrade != null) ? (mGrade as Float) >= 0.0 : true;
        var gCy = y0 + halfH + halfH / 2;
        var gTxt = "-- %";
        if (mGrade != null) {
            var g = mGrade as Float;
            gTxt = fmt1(g < 0.0 ? -g : g) + " %";
        }
        var chevS = halfH * 0.40;
        if (chevS > 24) { chevS = 24; }
        var chevW = chevS * 0.70;
        var gVW = dc.getTextWidthInPixels(gTxt, vF);
        var gTotal = chevW + 9 + gVW;
        var gx2 = (windW - gTotal) / 2;
        if (gx2 < 6) { gx2 = 6; }
        drawGradeArrow(dc, gx2 + chevW / 2, gCy, chevS, gradeUp, gc);
        dc.setColor(gc, Graphics.COLOR_TRANSPARENT);
        dc.drawText(gx2 + chevW + 9, gCy, vF, gTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(cDiv, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y0 + halfH, windW, 2);
    }

    // row 1 right tile: the kilometres group — distance + total ascent
    hidden function drawTallKmTile(dc as Dc, y0 as Number, colX as Number, colW as Number, row1H as Number, big as Boolean) as Void {
        var vF = big ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL;
        var sF = big ? Graphics.FONT_SMALL : Graphics.FONT_TINY;
        var uF = big ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var tileCx = colX + colW / 2;
        var kmTxt = (mElapsedKm != null) ? fmt1(mElapsedKm) : "--";
        drawValueUnitCenter(dc, tileCx, y0 + (row1H * 0.30).toNumber(), kmTxt,
            vF, "km", uF, cFg, cSub);
        var ascTxt = (mAscent != null) ? (mAscent as Float).toNumber().toString() : "--";
        var ascY = y0 + (row1H * 0.72).toNumber();
        var mtnS = big ? 20 : 15;
        var ascW = dc.getTextWidthInPixels(ascTxt, sF);
        var ascUW = dc.getTextWidthInPixels("m", uF);
        var ascTotal = mtnS + 5 + ascW + 4 + ascUW;
        var ascX = tileCx - ascTotal / 2;
        drawMountain(dc, ascX + mtnS / 2, ascY, mtnS, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(ascX + mtnS + 5, ascY, sF, ascTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
        dc.drawText(ascX + mtnS + 5 + ascW + 4, ascY + 2, uF, "m",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

    }

    // row 1 centre: the speed cluster — current + avg/max stacked beside it
    hidden function drawTallSpeed(dc as Dc, y0 as Number, windW as Number, colX as Number, row1H as Number, big as Boolean) as Void {
        var sF = big ? Graphics.FONT_SMALL : Graphics.FONT_TINY;
        var uF = big ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var spdTxt = fmt1(mSpd);
        var stAvgTxt = fmt1(mAvgSpd);
        var stMaxTxt = fmt1(mMaxSpd);
        var glyphR = big ? 7 : 6;
        var stTxtX = glyphR * 2 + 5;
        var stAW = dc.getTextWidthInPixels(stAvgTxt, sF);
        var stMW = dc.getTextWidthInPixels(stMaxTxt, sF);
        var stackW = stTxtX + (stAW > stMW ? stAW : stMW);
        var inset = 16;  // breathing room against the tile dividers
        var availX = windW + 2 + inset;
        var availW = colX - 2 - inset - availX;
        var unitSW = dc.getTextWidthInPixels("km/h", uF);
        var spdFont = pickFontH(dc, spdTxt, availW - stackW - 14 - 5 - unitSW, row1H * 1.05,
            [Graphics.FONT_NUMBER_THAI_HOT, Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        var spdW = dc.getTextWidthInPixels(spdTxt, spdFont);
        var groupW = spdW + 5 + unitSW + 14 + stackW;
        var gx = availX + (availW - groupW) / 2;
        if (gx < availX) { gx = availX; }
        var cy = y0 + row1H / 2;
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(gx, cy, spdFont, spdTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
        dc.drawText(gx + spdW + 5,
            cy + (dc.getFontHeight(spdFont) - dc.getFontHeight(uF)) * 0.26,
            uF, "km/h",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var stX = gx + spdW + 5 + unitSW + 14;
        var avgY = y0 + (row1H * 0.32).toNumber();
        var maxY = y0 + (row1H * 0.68).toNumber();
        drawAvgGlyph(dc, stX + glyphR, avgY, glyphR, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(stX + stTxtX, avgY, sF, stAvgTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawMaxGlyph(dc, stX + glyphR, maxY, glyphR, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(stX + stTxtX, maxY, sF, stMaxTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
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

        // taller blocks (half-screen slot) step up one type tier
        var big = bh >= 140;
        var aFont = big ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL;
        var zFont = big ? Graphics.FONT_SMALL : Graphics.FONT_TINY;
        var uFont = big ? Graphics.FONT_TINY : Graphics.FONT_XTINY;

        var cy = y + bh / 2;
        var pad = big ? 16 : 12;
        var iconS = bh * 0.24;
        if (isHr) {
            drawHeart(dc, x + pad + iconS / 2, cy, iconS, fg);
        } else {
            drawBolt(dc, x + pad + iconS / 2, cy, iconS * 1.1, fg);
        }
        var curTxt = (cur != null) ? (cur as Number).toString() : "--";
        var vFont = pickFontH(dc, curTxt, bw * 0.42, bh * 0.9,
            [Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<FontDefinition>);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + pad + iconS + 8, cy, vFont, curTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var vw2 = dc.getTextWidthInPixels(curTxt, vFont);
        dc.drawText(x + pad + iconS + 8 + vw2 + 6, cy + bh * 0.12, uFont,
            isHr ? "bpm" : "W",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var rx = x + bw - pad;
        var avgTxt = (avg != null) ? (avg as Number).toString() : "--";
        var avgY = y + (bh * 0.30).toNumber();
        dc.drawText(rx, avgY, aFont, avgTxt,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        var avgW = dc.getTextWidthInPixels(avgTxt, aFont);
        drawAvgGlyph(dc, rx - avgW - (big ? 16 : 12), avgY, big ? 8 : 6, fg);
        if (zone != null) {
            dc.drawText(rx, y + (bh * 0.68).toNumber(), zFont, "Z" + zone,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // ================= slim strip: four tiles in a row =================

    hidden function drawSlim(dc as Dc, w as Number, h as Number) as Void {
        var y0 = 2;
        var bh = h - y0;
        var inner = w - 6; // three 2px dividers
        // HR/power tiles get a little more room than design C so the bpm/W units fit
        var w0 = (inner * 0.19).toNumber();
        var w1 = (inner * 0.26).toNumber();
        var w2 = (inner * 0.275).toNumber();
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
        drawWindArrow(dc, cx, y + (bh * 0.38).toNumber(), bh * 0.34, tint);
        var windTxt = (mWindKmh != null) ? (mWindKmh as Number).toString() : "--";
        // design C: wind value one step below the speed/HR/power values
        drawValueUnitCenter(dc, cx, y + (bh * 0.72).toNumber(), windTxt,
            Graphics.FONT_SMALL, "km/h", Graphics.FONT_XTINY, cFg, cSub);
    }

    hidden function drawSlimSpeed(dc as Dc, x as Number, y as Number, bw as Number, bh as Number) as Void {
        var cx = x + bw / 2;
        var spdTxt = fmt1(mSpd);
        // the value + its km/h unit together must clear the dividers
        var unitW = dc.getTextWidthInPixels("km/h", Graphics.FONT_XTINY);
        var vFont = pickFontH(dc, spdTxt, bw - 20 - 4 - unitW, bh * 0.40,
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD, Graphics.FONT_SMALL] as Array<FontDefinition>);
        drawValueUnitCenter(dc, cx, y + (bh * 0.38).toNumber(), spdTxt, vFont,
            "km/h", Graphics.FONT_XTINY, cFg, cSub);

        // avg + max side by side
        var subY = y + (bh * 0.72).toNumber();
        var avgTxt = fmt1(mAvgSpd);
        var maxTxt = fmt1(mMaxSpd);
        var f = Graphics.FONT_XTINY;
        var aw = dc.getTextWidthInPixels(avgTxt, f);
        var mw = dc.getTextWidthInPixels(maxTxt, f);
        var total = 8 + 4 + aw + 14 + 8 + 4 + mw;
        var sx = cx - total / 2;
        drawAvgGlyph(dc, sx + 4, subY, 4, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sx + 12, subY, f, avgTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawMaxGlyph(dc, sx + 12 + aw + 14 + 4, subY, 4, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sx + 12 + aw + 14 + 12, subY, f, maxTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
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
        var topY = y + (bh * 0.38).toNumber();
        var curTxt = (cur != null) ? (cur as Number).toString() : "--";
        var unit = isHr ? "bpm" : "W";
        var uw = dc.getTextWidthInPixels(unit, Graphics.FONT_XTINY);
        var iconS = bh * 0.13;
        // keep a clear margin between the zone bar and the icon+value+unit group
        var margin = 6;
        var innerW = bw - 9 - margin * 2;
        var vFont = pickFont(dc, curTxt, innerW - iconS - 5 - 3 - uw,
            [Graphics.FONT_NUMBER_MILD, Graphics.FONT_SMALL] as Array<FontDefinition>);
        var vw = dc.getTextWidthInPixels(curTxt, vFont);
        var groupW = iconS + 5 + vw + 3 + uw;
        var gx = x + 9 + margin + (innerW - groupW) / 2;
        if (gx < x + 9 + margin) { gx = x + 9 + margin; }
        if (isHr) {
            drawHeart(dc, gx + iconS / 2, topY, iconS, zColor);
        } else {
            drawBolt(dc, gx + iconS / 2, topY, iconS * 1.1, zColor);
        }
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(gx + iconS + 5, topY, vFont, curTxt,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(cSub, Graphics.COLOR_TRANSPARENT);
        dc.drawText(gx + iconS + 5 + vw + 3,
            topY + (dc.getFontHeight(vFont) - dc.getFontHeight(Graphics.FONT_XTINY)) * 0.26,
            Graphics.FONT_XTINY, unit,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // zone label + average underneath — design C: label one step smaller than the value
        var subY = y + (bh * 0.72).toNumber();
        var zF = Graphics.FONT_XTINY;
        var aF = Graphics.FONT_TINY;
        var zTxt = (zone != null) ? "Z" + zone : "";
        var avgTxt = (avg != null) ? (avg as Number).toString() : "--";
        var zw = dc.getTextWidthInPixels(zTxt, zF);
        var aw = dc.getTextWidthInPixels(avgTxt, aF);
        var total = zw + 10 + 8 + 4 + aw;
        var sx = cx - total / 2;
        if (zone != null) {
            dc.setColor(zColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(sx, subY + 1, zF, zTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        drawAvgGlyph(dc, sx + zw + 10 + 4, subY, 4, cSub);
        dc.setColor(cFg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sx + zw + 10 + 12, subY, aF, avgTxt, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ================= glyphs =================

    // NOTE: glyphs call dc.fillPolygon directly — no shared helper. The device's
    // Connect IQ call stack is shallow and one extra frame in the draw chain
    // (onUpdate → tier → block → glyph → helper) overflows it on real hardware.
    // Shapes stay convex pieces: fillPolygon mis-renders concave polygons.

    // design-B navigation pointer, rotated to the relative bearing of the next point
    hidden function drawNavArrow(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, color as Number) as Void {
        var deg = (mBearingRelDeg != null) ? (mBearingRelDeg as Number).toFloat() : 0.0;
        var rad = deg * DEG_TO_RAD;
        var c = Math.cos(rad);
        var s = Math.sin(rad);
        var k = size / 24.0;
        // dart split down the middle into two triangles (offsets from centre)
        var pts = [[0.0, -10.4], [8.6, 10.4], [0.0, 5.9], [-8.6, 10.4]];
        var rp = new Array<Graphics.Point2D>[4];
        for (var i = 0; i < 4; i++) {
            var dx = pts[i][0] * k;
            var dy = pts[i][1] * k;
            rp[i] = [cx + dx * c - dy * s, cy + dx * s + dy * c] as Graphics.Point2D;
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([rp[0], rp[1], rp[2]]);
        dc.fillPolygon([rp[0], rp[2], rp[3]]);
    }

    // chevron pointing up (climbing) or down (descending), two parallelogram arms
    hidden function drawGradeArrow(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, up as Boolean, color as Number) as Void {
        var a = size * 0.19;      // half-height of the fold
        var wHalf = size * 0.33;  // half-width
        var t = size * 0.23;      // stroke thickness
        var f = up ? 1.0 : -1.0;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx - wHalf, cy + f * (a - t / 2)], [cx, cy - f * (a + t / 2)],
                        [cx, cy - f * (a - t / 2)], [cx - wHalf, cy + f * (a + t / 2)]]);
        dc.fillPolygon([[cx + wHalf, cy + f * (a - t / 2)], [cx, cy - f * (a + t / 2)],
                        [cx, cy - f * (a - t / 2)], [cx + wHalf, cy + f * (a + t / 2)]]);
    }

    // twin-peak mountain for total ascent (D+)
    hidden function drawMountain(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, color as Number) as Void {
        var base = cy + size * 0.38;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx - size * 0.15, base], [cx + size * 0.5, base], [cx + size * 0.12, cy - size * 0.42]]);
        dc.fillPolygon([[cx - size * 0.5, base], [cx + size * 0.05, base], [cx - size * 0.24, cy - size * 0.05]]);
    }

    hidden function drawClock(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, r);
        dc.drawLine(cx, cy - r * 0.55, cx, cy);
        dc.drawLine(cx, cy, cx + r * 0.45, cy + r * 0.25);
        dc.setPenWidth(1);
    }

    hidden function windLabel() as String {
        if (mWindRelDeg == null) {
            return "";
        }
        var deg = mWindRelDeg as Number;
        var off = (deg > 180) ? 360 - deg : deg;
        if (off <= 45) { return "TAILWIND"; }
        if (off >= 135) { return "HEADWIND"; }
        return "CROSSWIND";
    }

    hidden function drawWindArrow(dc as Dc, cx as Numeric, cy as Numeric, size as Numeric, color as Number) as Void {
        var deg = (mWindRelDeg != null) ? (mWindRelDeg as Number).toFloat() : 0.0;
        var rad = deg * DEG_TO_RAD;
        var c = Math.cos(rad);
        var s = Math.sin(rad);
        var k = size / 24.0;
        // triangle head + rectangular stem, both convex (offsets from centre)
        var pts = [[0.0, -9.6], [8.0, -0.2], [-8.0, -0.2],
                   [-3.4, -0.2], [3.4, -0.2], [3.4, 9.6], [-3.4, 9.6]];
        var rp = new Array<Graphics.Point2D>[7];
        for (var i = 0; i < 7; i++) {
            var dx = pts[i][0] * k;
            var dy = pts[i][1] * k;
            rp[i] = [cx + dx * c - dy * s, cy + dx * s + dy * c] as Graphics.Point2D;
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([rp[0], rp[1], rp[2]]);
        dc.fillPolygon([rp[3], rp[4], rp[5], rp[6]]);
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
        var k = size / 24.0;
        // no rotation — scaled centre offsets, drawn as four convex triangles
        var pTip = [cx + 1.4 * k, cy - 10.2 * k];
        var pL = [cx - 8.0 * k, cy + 1.9 * k];
        var pM = [cx - 1.7 * k, cy + 1.9 * k];
        var pB = [cx - 2.6 * k, cy + 10.2 * k];
        var pR = [cx + 7.6 * k, cy - 2.4 * k];
        var pC = [cx + 1.2 * k, cy - 2.4 * k];
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([pTip, pL, pM]);
        dc.fillPolygon([pTip, pM, pC]);
        dc.fillPolygon([pC, pM, pR]);
        dc.fillPolygon([pM, pB, pR]);
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

    hidden function fmtHMS(sec as Number) as String {
        var hh = sec / 3600;
        var mm = (sec % 3600) / 60;
        var ss = sec % 60;
        return hh.format("%d") + ":" + mm.format("%02d") + ":" + ss.format("%02d");
    }

    hidden function truncate(dc as Dc, text as String, font as FontDefinition, maxW as Numeric) as String {
        if (dc.getTextWidthInPixels(text, font) <= maxW) {
            return text;
        }
        var t = text;
        while (t.length() > 1 && dc.getTextWidthInPixels(t + "...", font) > maxW) {
            t = t.substring(0, t.length() - 1);
        }
        return t + "...";
    }

    hidden function pickFontH(dc as Dc, text as String, maxW as Numeric, maxH as Numeric, fonts as Array<FontDefinition>) as FontDefinition {
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getTextWidthInPixels(text, fonts[i]) <= maxW && dc.getFontHeight(fonts[i]) <= maxH) {
                return fonts[i];
            }
        }
        return fonts[fonts.size() - 1];
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
