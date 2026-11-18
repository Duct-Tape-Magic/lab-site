/* Colorimeter widget for the Lab Site (see docs/WIDGETS.md).
   Loaded on demand by index.html the first time a student taps Start on a \widget[type=colorimeter] block, and registers
   window.LabWidgets.colorimeter = { mount(stage, ctx) → { stop } }.
   The host (index.html) owns Start/Stop, the idle/running/failed states, and the Record path into the lab's data table.
   This file opens the camera (or draws a sample picture in demo mode) and reads two squares the student drags into place:
   a REFERENCE square on plain white printer paper and a SAMPLE square. The paper is taken as white, so every reading is
       corrected = sample × 255 / reference_now      (channel by channel, clamped to 0–255)
   The correction is continuous: changes in lighting, exposure and white balance move both squares together and cancel, and
   there is nothing to set. The widget keeps no memory; the squares start at their default places every run.
   One warning (v12): when the camera overexposes the paper itself (a quarter of the Reference square's pixels at or above
   CLIP on any channel), the reference is clipped and the corrected numbers are wrong, so the status line says so (text key
   widgetRefBright). Record is not blocked. Without the warning, a reading near 255 means "the same as the paper".
   The interface is deliberately bare: the picture, the two squares, the R G B readout and Record; a line of green text under the
   button says "Data recorded" for a second. Nothing is stored or sent anywhere by this file; the pixels stay in the browser.
   Auto record (v13): with interval=<seconds> on the block, a second button starts a timed run: one reading at once, then one
   every interval, until the student taps it again, the tool stops, the table is full, or `readings` readings are in
   (AUTO_MAX when not given). Each reading goes through the same ctx.record as a tap on Record; with timecolumn= set, the
   seconds since the run began go into that column (values.also.timecolumn). The screen is kept awake during a run where the
   browser allows it. A run does not survive Stop or the page being hidden (the host releases the camera).
   ctx: { opts, labId, demo, text(key), fmt(key, vars), canRecord() → {ok, reason}, record(values) → {ok, row | reason}, fail(why) }
   values: corrected R, G, B as strings, plus values.also = { rawcolumns: [R, G, B], timecolumn: [seconds] (auto record only) }.
   Continuous runs (v14): this file also registers window.LabWidgets['colorimeter-run'], the same camera and squares with a
   different output. The student picks one of the lab's runs (each run is a \datatable named in runs=) and taps Start
   recording; until they tap Stop recording (or the tool stops, or `minutes` pass) the tool writes one row every `interval`
   seconds: the time, and per channel the RELATIVE CONCENTRATION of whatever colours the sample:
       linear  = camera value converted from sRGB to linear light (pixel by pixel)
       A       = log10(reference_linear / sample_linear), averaged over every frame of the interval
       value   = A / A0                         when the colour FADES   (A0 = the run's first reading; the run starts at 1 and falls)
       value   = (A - A0) / largest (A - A0)    when colour FORMS       (the run starts at 0, at a clear sample, and rises to 1)
   Which of the two applies is read from the run itself, channel by channel: colour forms when A has risen above its
   starting value by more than it has fallen below it. Nothing is asked of the lab or the student, and a run may start on a
   clear sample (v15; v14 refused to). While colour forms the largest rise keeps growing, so the rows already written are
   rewritten to the new scale each reading (writer.set); the curve keeps its shape and only the axis numbers move. A divisor
   is never smaller than MIN_A, so a channel that shows no colour stays near 0 instead of magnifying noise.
   The student sees no numbers: the lab's \graph blocks draw the run as rows arrive.
   A run that already holds a recording is only replaced after a confirm (widgetRunReplace). Start is disabled while the
   reference is overexposed. Run ctx: runs() → [{ id, name, rows }], runClear(id),
   runWriter(id) → { add(time, [r, g, b]) → { ok, reason }, set(n, [r, g, b]) rewrites the values of the n-th row it added (0-based) },
   confirm(message). Single readings (window.LabWidgets.colorimeter) are exactly as in v13.
   v16: the writer is told when its run is over (writer.end()), so the host can offer Delete on the graphs again; and the run
   list is re-read once a second while nothing records, so a run deleted from a graph loses its "(recorded)" mark here.
   v17 (2026-11-18), continuous runs only:
   - Sample warnings. "Too dark" (widgetSampleDark): a recorded channel absorbs more than DARK_ON (the camera can no longer tell
     such a sample from black, and the trace is noise), or the sample is all but black. "Too pale" (widgetSamplePale): only when
     the lab says change=fades, and only when every recorded channel absorbs less than PALE_ON. Start recording waits while
     either shows, as it does for the bright reference. A run that is already recording is never stopped by a warning.
   - change=fades | forms fixes how the run is scaled. Without it the tool still works it out, but now with a margin, so noise
     on a flat signal cannot flip the scale back and forth (the "wild trace" of v16).
   - The starting value A0 no longer rests on one reading. It is the value at t = 0 of a line through every camera frame of
     the first START_SEC seconds, fitted by medians (Theil–Sen), so a few disturbed frames do not move it and the reaction's
     own progress during those seconds is not mistaken for the start. Rows already written follow as A0 settles.
   - mixtable=: a "Mixed now" button (widgetRunMix). The seconds from that tap to Start recording go to ctx.runMix(id, seconds),
     which the host writes into the lab's table. The mark is this run only; the widget keeps no memory.
   Run ctx additions: runs() entries carry channels [r, g, b] (which channels the run records); runMix(id, seconds) → bool.
   New version → new filename (colorimeter.v18.js) and update the file of BOTH catalog entries in index.html. */
(function () {
  'use strict';
  var W = window.LabWidgets = window.LabWidgets || {};
  var SMOOTH = 10;          // frames averaged so the numbers hold steady
  var PERIOD_MS = 100;      // about 10 readings a second
  var SAMPLE_PX = 16;       // each square is scaled down to this many pixels across before averaging
  var CLIP = 250;           // a pixel with any channel at or above this counts as overexposed
  var BRIGHT_ON = 0.25, BRIGHT_OFF = 0.10;   // share of the Reference square that must be overexposed to show the warning, and to clear it
  var AUTO_MAX = 200;       // readings in one auto-record run when the block gives no readings=
  var REGION = 16;          // side of each square in picture pixels (old files may still carry region=)
  var MIN_A = 0.02;         // continuous runs: the smallest absorbance a value is ever divided by; below it a channel shows no colour
  var FLOOR = 1e-4;         // continuous runs: the darkest linear value used, so a black sample cannot divide by zero
  var RUN_MAX = 1200;       // continuous runs: readings in one run at most
  var DEMO_TAU = 30;        // continuous runs, demo picture: the sample fades (or, in every second run of the list, gains colour) with this time constant (seconds), first order
  var DARK_ON = 1.5, DARK_OFF = 1.4;       // continuous runs: absorbance in a recorded channel at which the sample is too dark to measure, and at which the warning clears
  var BLACK_ON = 0.002, BLACK_OFF = 0.003; // continuous runs: linear-light value of the sample below which it is all but black whatever the reference reads
  var PALE_ON = 0.08, PALE_OFF = 0.1;      // continuous runs, change=fades: absorbance below which a channel has too little colour to follow as it fades
  var START_SEC = 4;        // continuous runs: the starting value is read from the camera frames of this many seconds
  function median(a) { var b = a.slice().sort(function (x, y) { return x - y; }), n = b.length; return n ? (n % 2 ? b[(n - 1) / 2] : (b[n / 2 - 1] + b[n / 2]) / 2) : NaN; }
  function startValue(frames, ch) {   // frames: [t, Ar, Ag, Ab]. The value at t = 0 of a line through them, by medians; with under two seconds of frames, their median.
    var n = frames.length; if (!n) return NaN;
    var ys = frames.map(function (f) { return f[1 + ch]; });
    if (frames[n - 1][0] - frames[0][0] < 2) return median(ys);
    var slopes = [], step = Math.max(1, Math.floor(n / 60));
    for (var i = 0; i < n; i += step) for (var j = i + step; j < n; j += step) { var dt = frames[j][0] - frames[i][0]; if (dt > 0.5) slopes.push((ys[j] - ys[i]) / dt); }
    if (!slopes.length) return median(ys);
    var m = median(slopes);
    return median(frames.map(function (f, k) { return ys[k] - m * f[0]; }));
  }
  var LIN = []; for (var li = 0; li < 256; li++) { var lv = li / 255; LIN.push(lv <= 0.04045 ? lv / 12.92 : Math.pow((lv + 0.055) / 1.055, 2.4)); }   // sRGB byte → linear light
  function toByte(v) { v = Math.max(0, Math.min(1, v)); return Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055)); }
  function fill(s, vars) { return String(s).replace(/\{(\w+)\}/g, function (m, k) { return vars[k] != null ? vars[k] : m; }); }   // plain text (ctx.fmt escapes for HTML)
  function clockText(sec) { sec = Math.max(0, Math.floor(sec)); var m = Math.floor(sec / 60), r = sec % 60; return m + ':' + (r < 10 ? '0' : '') + r; }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  function mount(isRun, stage, ctx) {
      var opts = ctx.opts || {};
      var t = function (k) { return ctx.text(k); };
      var every = parseFloat(opts.interval); every = every > 0 ? Math.min(3600, Math.max(1, every)) : (isRun ? 1 : 0);   // seconds between readings; single readings: 0 = no auto record
      var maxSec = parseFloat(opts.minutes); maxSec = (maxSec > 0 ? Math.min(60, maxSec) : 10) * 60;   // continuous runs: a forgotten run ends by itself
      var autoMax = parseInt(opts.readings, 10); autoMax = autoMax > 0 ? Math.min(1000, autoMax) : AUTO_MAX;
      var change = String(opts.change || '').toLowerCase(); change = change === 'fades' || change === 'forms' ? change : '';   // continuous runs: what the lab says the colour does; '' = worked out from the run
      var canMix = isRun && !!opts.mixtable && opts.mixtable !== true && typeof ctx.runMix === 'function';
      var pos = { ref: { x: 0.22, y: 0.5 }, meas: { x: 0.62, y: 0.5 } };   // square centres as fractions of the picture; this run only

      stage.innerHTML = '<div class="cm">' +
        '<div class="cm-view">' + (ctx.demo ? '<canvas class="cm-src" width="320" height="240"></canvas>' : '<video playsinline muted autoplay></video>') +
          '<div class="cm-box ref" data-role="ref"><span class="cm-sq"></span><span class="cm-tag">' + esc(t('widgetRefLabel')) + '</span></div>' +
          '<div class="cm-box meas" data-role="meas"><span class="cm-sq"></span><span class="cm-tag">' + esc(t('widgetMeasLabel')) + '</span></div>' +
        '</div>' +
        '<div class="cm-side">' +
          '<div class="cm-swatch"></div>' +
          (isRun
            ? '<select class="cm-runs" hidden></select>' +
              '<div class="cm-actions">' + (canMix ? '<button type="button" class="btn-small cm-mix">' + esc(t('widgetRunMix')) + '</button>' : '') + '<button type="button" class="btn-small btn-primary-small cm-run" disabled>' + esc(t('widgetRunStart')) + '</button><span class="cm-clock"></span></div>'
            : '<div class="cm-nums"><div class="cm-num"><b data-ch="0">–</b><span>R</span></div><div class="cm-num"><b data-ch="1">–</b><span>G</span></div><div class="cm-num"><b data-ch="2">–</b><span>B</span></div></div>' +
              '<div class="cm-actions"><button type="button" class="btn-small btn-primary-small cm-record" disabled>' + esc(t('widgetRecord')) + '</button>' + (every ? '<button type="button" class="btn-small cm-auto" disabled>' + esc(t('widgetAutoStart')) + '</button>' : '') + '</div>') +
          '<div class="cm-status">&nbsp;</div>' +
        '</div></div>';

      var q = function (s) { return stage.querySelector(s); };
      var view = q('.cm-view'), video = q('video'), demoSrc = q('canvas.cm-src');
      var boxes = { ref: q('.cm-box.ref'), meas: q('.cm-box.meas') };
      var swatch = q('.cm-swatch'), nums = [q('[data-ch="0"]'), q('[data-ch="1"]'), q('[data-ch="2"]')];
      var recBtn = q('.cm-record'), autoBtn = q('.cm-auto'), status = q('.cm-status');
      var runBtn = q('.cm-run'), runSel = q('.cm-runs'), clock = q('.cm-clock'), mixBtn = q('.cm-mix');
      var dark = false, pale = false, mixAt = 0;   // the two sample warnings; when Mixed now was tapped (0 = not marked)
      var run = null, runNote = '', runList = [], runSig = '', pollN = 0;   // run: the recording in progress; runNote: why the last one ended, shown until the next Start
      var work = document.createElement('canvas'); work.width = work.height = SAMPLE_PX;
      var wctx = work.getContext('2d', { willReadFrequently: true });
      var stream = null, timer = null, hist = { ref: [], meas: [] }, cur = null, stopped = false, demoT = 0, drag = null, sayTimer = null, bright = false, auto = null, lock = null;

      function say(msg) {   // green confirmation under the button, gone after one second
        status.textContent = msg; status.classList.remove('warn'); status.classList.add('ok');
        clearTimeout(sayTimer); sayTimer = setTimeout(function () { status.classList.remove('ok'); refreshRecord(); }, 1000);
      }
      function refreshRecord() {   // Record is disabled, with the reason shown, only when the table cannot take another reading
        if (isRun) { refreshRun(); return; }
        var can = ctx.canRecord ? ctx.canRecord() : { ok: false };
        recBtn.disabled = !can.ok || !cur || !!auto;   // during a timed run only the run records
        if (autoBtn) autoBtn.disabled = !auto && (!can.ok || !cur);
        if (status.classList.contains('ok')) return;
        var why = !can.ok && can.reason ? can.reason : '';   // the table's reason comes before the warning
        status.classList.toggle('warn', bright && !why);
        status.textContent = why || (bright ? t('widgetRefBright') : ' ');
      }
      function source() {
        if (demoSrc) return { el: demoSrc, w: demoSrc.width, h: demoSrc.height };
        if (video && video.readyState >= 2 && video.videoWidth) return { el: video, w: video.videoWidth, h: video.videoHeight };
        return null;
      }
      function regionSide(w, h) { var r = parseInt(opts.region, 10); return Math.max(4, Math.min(r > 0 ? r : REGION, w, h)); }
      function geom(s) {   // the picture is shown with object-fit: cover; map picture pixels to the view
        var vw = view.clientWidth, vh = view.clientHeight, scale = Math.max(vw / s.w, vh / s.h) || 1;
        return { scale: scale, ox: (vw - s.w * scale) / 2, oy: (vh - s.h * scale) / 2, vw: vw, vh: vh };
      }
      function clampPos(s, p) {   // keep a square whole, and inside the part of the picture that is visible
        var g = geom(s), m = regionSide(s.w, s.h) / 2;
        var x0 = Math.max(m / s.w, (-g.ox) / (s.w * g.scale)), x1 = Math.min(1 - m / s.w, (g.vw - g.ox) / (s.w * g.scale));
        var y0 = Math.max(m / s.h, (-g.oy) / (s.h * g.scale)), y1 = Math.min(1 - m / s.h, (g.vh - g.oy) / (s.h * g.scale));
        return { x: Math.max(x0, Math.min(x1, p.x)), y: Math.max(y0, Math.min(y1, p.y)) };
      }
      function place(s) {
        var g = geom(s), px = Math.max(12, Math.round(regionSide(s.w, s.h) * g.scale));
        Object.keys(boxes).forEach(function (k) {
          var b = boxes[k], sq = b.querySelector('.cm-sq');
          b.style.left = (g.ox + pos[k].x * s.w * g.scale) + 'px'; b.style.top = (g.oy + pos[k].y * s.h * g.scale) + 'px';
          sq.style.width = sq.style.height = px + 'px';
        });
      }
      Object.keys(boxes).forEach(function (k) {   // drag a square with a finger or the mouse
        var b = boxes[k];
        b.addEventListener('pointerdown', function (e) { if (!source()) return; e.preventDefault(); try { b.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ } drag = { k: k, id: e.pointerId }; b.classList.add('dragging'); });
        b.addEventListener('pointermove', function (e) {
          if (!drag || drag.k !== k || e.pointerId !== drag.id) return;
          var s = source(); if (!s) return;
          var g = geom(s), r = view.getBoundingClientRect();
          pos[k] = clampPos(s, { x: (e.clientX - r.left - g.ox) / (s.w * g.scale), y: (e.clientY - r.top - g.oy) / (s.h * g.scale) });
          place(s);
        });
        var end = function () { if (!drag || drag.k !== k) return; drag = null; b.classList.remove('dragging'); hist = { ref: [], meas: [] }; };
        b.addEventListener('pointerup', end); b.addEventListener('pointercancel', end);
      });
      function drawDemo() {   // a bench, a sheet of white paper, a blue tube, and lighting that keeps changing
        var c = demoSrc.getContext('2d'); demoT += 0.02;
        c.fillStyle = '#8f8a84'; c.fillRect(0, 0, 320, 240);
        c.fillStyle = '#f4f2ee'; c.fillRect(36, 68, 72, 104);
        c.fillStyle = 'rgb(38, 112, 186)'; c.fillRect(170, 56, 56, 128);
        c.fillStyle = 'hsla(' + ((demoT * 20) % 360) + ', 60%, 50%, ' + (0.22 + 0.18 * Math.sin(demoT)).toFixed(3) + ')'; c.fillRect(0, 0, 320, 240);
      }
      function drawRunDemo() {   // the same scene in linear light: the lighting drifts by multiplying every colour, and the tube fades (first order) while a run records
        var c = demoSrc.getContext('2d'); demoT += 0.02;
        var L = [1 + 0.12 * Math.sin(demoT * 1.3), 1 + 0.12 * Math.sin(demoT * 0.9 + 1), 1 + 0.12 * Math.sin(demoT * 0.7 + 2)];
        var left = run ? Math.exp(-((Date.now() - run.t0) / 1000) / DEMO_TAU) : 1, T0 = [0.08, 0.3, 0.7], paper = 0.72;
        if (run && run.forms) left = 1 - left;   // this run starts clear and gains colour
        var css = function (lin) { return 'rgb(' + lin.map(function (v, i) { return toByte(v * L[i]); }).join(',') + ')'; };
        c.fillStyle = css([0.26, 0.25, 0.23]); c.fillRect(0, 0, 320, 240);
        c.fillStyle = css([paper, paper, paper]); c.fillRect(36, 68, 72, 104);
        c.fillStyle = css(T0.map(function (v) { return paper * Math.pow(v, left); })); c.fillRect(170, 56, 56, 128);
      }
      function sampleAt(s, p, side) {
        wctx.drawImage(s.el, p.x * s.w - side / 2, p.y * s.h - side / 2, side, side, 0, 0, SAMPLE_PX, SAMPLE_PX);
        var d = wctx.getImageData(0, 0, SAMPLE_PX, SAMPLE_PX).data, n = d.length / 4, r = 0, g = 0, b = 0, hot = 0, lr = 0, lg = 0, lb = 0;
        for (var i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; if (d[i] >= CLIP || d[i + 1] >= CLIP || d[i + 2] >= CLIP) hot++; if (isRun) { lr += LIN[d[i]]; lg += LIN[d[i + 1]]; lb += LIN[d[i + 2]]; } }
        return [r / n, g / n, b / n, hot / n, lr / n, lg / n, lb / n];   // the fourth number is the share of overexposed pixels; the last three are the linear-light means (continuous runs)
      }
      function smooth(k, v) { var h = hist[k]; h.push(v); if (h.length > SMOOTH) h.shift(); return [0, 1, 2, 3, 4, 5, 6].map(function (i) { return h.reduce(function (a, x) { return a + x[i]; }, 0) / h.length; }); }
      function sampleCheck(ref, raw) {   // continuous runs: is the sample too dark, or (change=fades) too pale, in the channels the chosen run records?
        var pick = runList.filter(function (r) { return r.id === runSel.value; })[0], ch = pick && pick.channels ? pick.channels : [true, true, true];
        if (!ch[0] && !ch[1] && !ch[2]) ch = [true, true, true];
        var anyDark = false, allPale = true;
        for (var i = 0; i < 3; i++) {
          if (!ch[i]) continue;
          var A = Math.log(Math.max(ref[4 + i], FLOOR) / Math.max(raw[4 + i], FLOOR)) / Math.LN10;
          if (A > (dark ? DARK_OFF : DARK_ON) || raw[4 + i] < (dark ? BLACK_OFF : BLACK_ON)) anyDark = true;
          if (!(A < (pale ? PALE_OFF : PALE_ON))) allPale = false;
        }
        dark = anyDark; pale = change === 'fades' && allPale && !anyDark;
      }
      function correct(raw, ref) { return raw.slice(0, 3).map(function (v, i) { return Math.max(0, Math.min(255, v * 255 / Math.max(1, ref[i]))); }); }   // the paper is white
      function show(c) {
        var rgb = correct(c.raw, c.ref).map(function (v) { return Math.round(v); });
        nums.forEach(function (el, i) { if (el) el.textContent = rgb[i]; });
        swatch.style.background = 'rgb(' + rgb.join(',') + ')';
      }
      function tick() {
        if (stopped) return;
        if (demoSrc) { if (isRun) drawRunDemo(); else drawDemo(); }
        var s = source(); if (!s) return;
        place(s);
        var side = regionSide(s.w, s.h), ref, raw, fr, fm;
        try { fr = sampleAt(s, pos.ref, side); fm = sampleAt(s, pos.meas, side); ref = smooth('ref', fr); raw = smooth('meas', fm); } catch (e) { return; }
        var was = bright, wasDark = dark, wasPale = pale; bright = ref[3] >= (bright ? BRIGHT_OFF : BRIGHT_ON);
        if (isRun) sampleCheck(ref, raw);
        var first = !cur; cur = { raw: raw.slice(0, 3), ref: ref.slice(0, 3) }; show(cur);
        if (first || was !== bright || wasDark !== dark || wasPale !== pale) refreshRecord();
        if (isRun && !run && mixAt) clock.textContent = fill(t('widgetRunMixed'), { time: clockText((Date.now() - mixAt) / 1000) });
        if (isRun) { runStep(Date.now(), fr, fm); if (++pollN % 10 === 0) pollRuns(); } else autoStep(Date.now());
      }
      function take(seconds) {   // one reading into the table; seconds is given only by a timed run
        var round = function (c) { return c.map(function (v) { return String(Math.round(v)); }); };
        var vals = round(correct(cur.raw, cur.ref)); vals.also = { rawcolumns: round(cur.raw) };
        if (seconds != null) vals.also.timecolumn = [seconds];
        var r = null;
        try { r = ctx.record(vals); } catch (e) { r = { ok: false, reason: e && e.message }; }
        if (r && r.ok) say(t('widgetRecorded'));
        else { status.classList.remove('ok'); status.classList.remove('warn'); status.textContent = (r && r.reason) || t('widgetFailed'); }
        return !!(r && r.ok);
      }
      if (recBtn) recBtn.addEventListener('click', function () {
        if (!cur || auto) return;
        var can = ctx.canRecord ? ctx.canRecord() : { ok: true };
        if (!can.ok) { refreshRecord(); return; }
        take(null);
        refreshRecord();
      });
      function autoEnd() {
        auto = null;
        if (lock) { try { lock.release(); } catch (e) { /* ignore */ } lock = null; }
        if (autoBtn) autoBtn.textContent = t('widgetAutoStart');
        refreshRecord();
      }
      function autoStep(now) {   // called every tick: record when the next reading is due
        if (!auto || !cur) return;
        var el = (now - auto.t0) / 1000;
        if (el < auto.n * every) return;
        var can = ctx.canRecord ? ctx.canRecord() : { ok: true };
        if (!can.ok) { autoEnd(); return; }   // the table is full: the run ends and the reason shows
        var ok = take(every % 1 ? el.toFixed(1) : String(Math.round(el)));
        auto.count++; auto.n = Math.floor(el / every) + 1;   // a late tick records once; missed slots are skipped, and the time written is the real one
        if (!ok || auto.count >= autoMax) autoEnd();
      }
      if (autoBtn) autoBtn.addEventListener('click', function () {
        if (auto) { autoEnd(); return; }
        if (!cur) return;
        var can = ctx.canRecord ? ctx.canRecord() : { ok: true };
        if (!can.ok) { refreshRecord(); return; }
        auto = { t0: Date.now(), n: 0, count: 0 };
        autoBtn.textContent = t('widgetAutoStop');
        try { if (navigator.wakeLock && navigator.wakeLock.request) navigator.wakeLock.request('screen').then(function (l) { if (auto && !stopped) lock = l; else l.release(); }).catch(function () { /* not allowed: the run goes on */ }); } catch (e) { /* ignore */ }
        refreshRecord();
        autoStep(Date.now());   // the first reading, at 0 s
      });
      /* ---- continuous runs ---- */
      function runName(r) { return r.rows ? fill(t('widgetRunRecorded'), { name: r.name }) : r.name; }
      function refreshRuns(pickEmpty) {   // the picker: one entry per run of the lab, recorded ones marked; shown only when there is a choice
        runList = ctx.runs ? ctx.runs() : [];
        runSig = runSignature(runList);
        var keep = runSel.value;
        runSel.innerHTML = '';
        runList.forEach(function (r) { var o = document.createElement('option'); o.value = r.id; o.textContent = runName(r); runSel.appendChild(o); });
        var empty = runList.filter(function (r) { return !r.rows; })[0];
        if (pickEmpty && empty) runSel.value = empty.id;
        else if (keep && runList.some(function (r) { return r.id === keep; })) runSel.value = keep;
        runSel.hidden = runList.length < 2;
      }
      function runSignature(list) { return list.map(function (r) { return r.id + (r.rows ? '+' : '-') + r.name; }).join('|'); }
      function pollRuns() {   // a run was deleted from its graph (or filled on another path): the list follows, without disturbing an open list that has not changed
        if (run || !ctx.runs) return;
        if (runSignature(ctx.runs()) !== runSig) { refreshRuns(false); refreshRun(); }
      }
      function refreshRun() {
        runBtn.disabled = !run && (!cur || bright || dark || pale || !runList.length);   // a warning holds Start back; it never stops a run that is recording
        runSel.disabled = !!run;
        if (mixBtn) mixBtn.disabled = !!run || !runList.length;
        if (status.classList.contains('ok')) return;
        var why = !runList.length ? t('widgetNoTable') : runNote;
        var warn = bright ? t('widgetRefBright') : dark ? t('widgetSampleDark') : pale && !run ? t('widgetSamplePale') : '';   // a colour that fades ends pale: no warning for that while it records
        status.classList.toggle('warn', !why && !!warn);
        status.textContent = why || warn || '\xa0';
      }
      function runEnd(note) {   // rows are saved as they are written, so whatever was recorded stays
        var had = run && run.count, w = run && run.writer;
        run = null; runNote = note || '';
        if (w && w.end) { try { w.end(); } catch (e) { /* ignore */ } }
        if (lock) { try { lock.release(); } catch (e) { /* ignore */ } lock = null; }
        runBtn.textContent = t('widgetRunStart'); clock.textContent = '';
        refreshRuns(true);
        if (had && !runNote) say(t('widgetRunDone')); else { status.classList.remove('ok'); refreshRun(); }
      }
      function runEmit() {   // the window that just closed becomes one row; false when the run ended here
        var a = run.acc; if (!a.n) return true;   // no frame arrived in this window (a stalled page): no row
        var A = [0, 1, 2].map(function (i) { return Math.log(Math.max(a.ref[i] / a.n, FLOOR) / Math.max(a.meas[i] / a.n, FLOOR)) / Math.LN10; });
        if (!run.hi) { run.hi = A.slice(); run.lo = A.slice(); }
        else A.forEach(function (v, i) { if (v > run.hi[i]) run.hi[i] = v; if (v < run.lo[i]) run.lo[i] = v; });
        if (!run.a0 || !run.settled) {   // the starting value, from every frame of the first seconds; fixed once those seconds are over
          run.a0 = [0, 1, 2].map(function (i) { var v = startValue(run.early, i); return isFinite(v) ? v : A[i]; });
          if (run.k * every >= START_SEC) { run.settled = true; run.early = []; }
        }
        if (!run.dir) run.dir = run.a0.map(function (v) { return v < 2 * MIN_A; });   // a clear start can only gain colour
        var scale = [0, 1, 2].map(function (i) {   // per channel: has colour formed (count from the start, relative to the largest rise) or faded (relative to the start)?
          var a0 = run.a0[i], rise = run.hi[i] - a0, fall = a0 - run.lo[i], margin = Math.max(MIN_A, 0.1 * Math.abs(a0));
          if (change) run.dir[i] = change === 'forms';   // the lab said which
          else if (!run.dir[i] && rise > fall + margin) run.dir[i] = true;   // worked out from the run, with a margin so noise on a flat signal cannot flip it
          else if (run.dir[i] && fall > rise + margin) run.dir[i] = false;
          return run.dir[i] ? { sub: a0, div: Math.max(rise, MIN_A) } : { sub: 0, div: Math.max(a0, MIN_A) };
        });
        var value = function (abs) { return abs.map(function (v, i) { return String(+((v - scale[i].sub) / scale[i].div).toFixed(4)); }); };
        var tm = run.k * every, r = null, out = value(A);
        try {
          run.series.forEach(function (row, n) { var nv = value(row.A); if (nv.join() !== row.out.join()) { run.writer.set(n, nv); row.out = nv; } });   // the scale moved: earlier rows follow
          r = run.writer.add(every % 1 ? tm.toFixed(1) : String(tm), out);
        } catch (e) { r = { ok: false, reason: e && e.message }; }
        if (!r || !r.ok) { runEnd((r && r.reason) || t('widgetFailed')); return false; }
        run.series.push({ A: A, out: out });
        run.count++; return true;
      }
      function runStep(now, fr, fm) {   // called every tick. Reading k is the mean of the frames within half an interval of k × interval.
        if (!run) return;
        var el = (now - run.t0) / 1000;
        clock.textContent = clockText(el);
        if (el >= (run.k + 0.5) * every) {
          if (!runEmit()) return;
          run.k = Math.floor(el / every + 0.5); run.acc = { ref: [0, 0, 0], meas: [0, 0, 0], n: 0 };
          if (run.count >= RUN_MAX || el >= maxSec) { runEnd(''); return; }
        }
        for (var i = 0; i < 3; i++) { run.acc.ref[i] += fr[4 + i]; run.acc.meas[i] += fm[4 + i]; }
        run.acc.n++;
        if (!run.settled && el <= START_SEC) run.early.push([el].concat([0, 1, 2].map(function (i) { return Math.log(Math.max(fr[4 + i], FLOOR) / Math.max(fm[4 + i], FLOOR)) / Math.LN10; })));   // this frame's absorbance, for the starting value
      }
      if (mixBtn) mixBtn.addEventListener('click', function () {   // the moment of mixing; a second tap marks it again
        if (run) return;
        mixAt = Date.now(); clock.textContent = fill(t('widgetRunMixed'), { time: clockText(0) });
      });
      if (runBtn) runBtn.addEventListener('click', function () {
        if (run) { runEnd(''); return; }
        if (!cur || bright || dark || pale) return;
        refreshRuns(false);
        var pick = runList.filter(function (r) { return r.id === runSel.value; })[0]; if (!pick) { refreshRun(); return; }
        if (pick.rows) {   // never over a recording without asking
          if (!ctx.confirm || !ctx.confirm(fill(t('widgetRunReplace'), { name: pick.name }))) return;
          if (!ctx.runClear(pick.id)) { runNote = t('widgetFailed'); refreshRun(); return; }
        }
        var writer = ctx.runWriter(pick.id); if (!writer) { runNote = t('widgetNoTable'); refreshRun(); return; }
        runNote = ''; status.classList.remove('ok');
        var now = Date.now();
        if (canMix && mixAt) { try { ctx.runMix(pick.id, ((now - mixAt) / 1000).toFixed(1)); } catch (e) { /* the run goes on without its delay */ } }
        mixAt = 0;
        run = { id: pick.id, t0: now, k: 0, count: 0, a0: null, hi: null, lo: null, dir: null, early: [], settled: false, series: [], writer: writer, acc: { ref: [0, 0, 0], meas: [0, 0, 0], n: 0 }, forms: !!ctx.demo && (change ? change === 'forms' : runList.indexOf(pick) % 2 === 1) };   // series: this run's absorbances, kept only while it records
        runBtn.textContent = t('widgetRunStop'); clock.textContent = clockText(0);
        try { if (navigator.wakeLock && navigator.wakeLock.request) navigator.wakeLock.request('screen').then(function (l) { if (run && !stopped) lock = l; else l.release(); }).catch(function () { /* not allowed: the run goes on */ }); } catch (e) { /* ignore */ }
        refreshRun();
      });
      if (runSel) runSel.addEventListener('change', function () { hist = { ref: [], meas: [] }; });   // another run may record other channels: the warnings are read afresh
      if (isRun) refreshRuns(true);
      function release() {
        clearInterval(timer); timer = null;
        if (stream) { try { stream.getTracks().forEach(function (tr) { tr.stop(); }); } catch (e) { /* ignore */ } stream = null; }
        if (video) { try { video.pause(); video.srcObject = null; } catch (e) { /* ignore */ } }
      }
      function loop() { if (stopped) return; clearInterval(timer); timer = setInterval(tick, PERIOD_MS); refreshRecord(); }
      function start() {
        if (ctx.demo) { loop(); return; }
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { ctx.fail('nocamera'); return; }
        var constraints = { video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false };
        navigator.mediaDevices.getUserMedia(constraints)
          .catch(function (e) {
            if (e && (e.name === 'NotAllowedError' || e.name === 'SecurityError')) throw e;
            return navigator.mediaDevices.getUserMedia({ video: true, audio: false });   // no rear camera: any camera
          })
          .then(function (s) {
            if (stopped) { try { s.getTracks().forEach(function (tr) { tr.stop(); }); } catch (e) { /* ignore */ } return; }
            stream = s; video.srcObject = s;
            var p = video.play(); if (p && p.catch) p.catch(function () { /* the autoplay attributes carry it on iOS */ });
            s.getVideoTracks().forEach(function (tr) { tr.addEventListener('ended', function () { if (!stopped) ctx.fail('died'); }); });
            loop();
          })
          .catch(function (e) {
            console.warn('colorimeter', e);
            var n = e && e.name;
            ctx.fail(n === 'NotAllowedError' || n === 'SecurityError' ? 'denied' : (n === 'NotFoundError' || n === 'DevicesNotFoundError' || n === 'OverconstrainedError') ? 'nocamera' : 'died');
          });
      }
      start();
      return { stop: function () { stopped = true; auto = null; if (run && run.writer && run.writer.end) { try { run.writer.end(); } catch (e) { /* ignore */ } } run = null; clearTimeout(sayTimer); if (lock) { try { lock.release(); } catch (e) { /* ignore */ } lock = null; } release(); } };
  }
  W.colorimeter = { mount: function (stage, ctx) { return mount(false, stage, ctx); } };
  W['colorimeter-run'] = { mount: function (stage, ctx) { return mount(true, stage, ctx); } };
})();
