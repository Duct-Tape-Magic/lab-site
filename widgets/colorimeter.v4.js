/* Colorimeter widget for the Lab Site (see docs/WIDGETS.md).
   Loaded on demand by index.html the first time a student taps Start on a \widget[type=colorimeter] block, and registers
   window.LabWidgets.colorimeter = { mount(stage, ctx) → { stop } }.
   The host (index.html) owns Start/Stop, the idle/running/failed states, and the Record path into the lab's data table.
   This file opens the camera (or draws a sample picture in demo mode) and reads two squares the student drags into place:
   a REFERENCE square on any matte object that stays under the same light for the whole lab, and a SAMPLE square.
   "Set reference" stores the reference's reading as the baseline; from then on
       corrected = sample × baseline / reference_now      (channel by channel)
   so changes in lighting, exposure and white balance, which move both squares together, mostly cancel. The reference needs no
   known colour: a mid-tone object is better than a white one, which the camera clips. If Record is tapped before a reference is
   set, the current reference reading becomes the baseline. The widget keeps no memory: the baseline lives only while it runs
   and is dropped on Stop or on leaving the lab, and the squares start at their default places every time. The data table holds
   the data. Nothing is stored or sent anywhere by this file; the pixels stay in the browser.
   ctx: { opts, labId, demo, text(key), fmt(key, vars), canRecord() → {ok, reason}, record(values) → {ok, row | reason}, fail(why) }
   values: corrected R, G, B as strings, plus values.also = { rawcolumns: [R, G, B] } and values.sample.
   New version → new filename (colorimeter.v5.js) and update WIDGETS.colorimeter.file in index.html. */
(function () {
  'use strict';
  var W = window.LabWidgets = window.LabWidgets || {};
  var SMOOTH = 10;          // frames averaged so the numbers hold steady
  var PERIOD_MS = 100;      // about 10 readings a second
  var SAMPLE_PX = 16;       // each square is scaled down to this many pixels across before averaging
  var REGION = 16;          // side of each square in picture pixels (old files may still carry region=)
  var DRIFT = 0.4;          // warn when the reference has moved this far (fraction) from the baseline
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function rgbText(c) { return c.map(function (v) { return Math.round(v); }).join(', '); }

  W.colorimeter = {
    mount: function (stage, ctx) {
      var opts = ctx.opts || {};
      var t = function (k) { return ctx.text(k); };
      var mem = { ref: { x: 0.22, y: 0.5 }, meas: { x: 0.62, y: 0.5 }, base: null };   // square centres as fractions of the picture; the baseline reading. Lives only for this run.

      stage.innerHTML = '<div class="cm">' +
        '<div class="cm-view">' + (ctx.demo ? '<canvas class="cm-src" width="320" height="240"></canvas>' : '<video playsinline muted autoplay></video>') +
          '<div class="cm-box ref" data-role="ref"><span class="cm-sq"></span><span class="cm-tag">' + esc(t('widgetRefLabel')) + '</span></div>' +
          '<div class="cm-box meas" data-role="meas"><span class="cm-sq"></span><span class="cm-tag">' + esc(t('widgetMeasLabel')) + '</span></div>' +
        '</div>' +
        '<div class="cm-side">' +
          '<div class="cm-swatch"></div>' +
          '<div class="cm-nums"><div class="cm-num"><b data-ch="0">–</b><span>R</span></div><div class="cm-num"><b data-ch="1">–</b><span>G</span></div><div class="cm-num"><b data-ch="2">–</b><span>B</span></div></div>' +
          '<div class="cm-hex">&nbsp;</div>' +
          '<div class="cm-small"><span class="cm-k">' + esc(t('widgetCorrectedLabel')) + '</span> ' + esc(t('widgetCorrectedNote')) + '</div>' +
          '<div class="cm-small"><span class="cm-k">' + esc(t('widgetCameraLabel')) + '</span> <span data-raw>–</span></div>' +
          '<div class="cm-small"><span class="cm-k">' + esc(t('widgetRefLabel')) + '</span> <span data-ref>–</span></div>' +
          '<div class="cm-refrow"><button type="button" class="btn-small cm-setref">' + esc(t('widgetSetRef')) + '</button><span class="cm-refnote"></span></div>' +
          '<div class="cm-warn" hidden></div>' +
          (opts.sample ? '<div class="cm-sample"><label>' + esc(t('widgetSampleLabel')) + '</label><input type="text" maxlength="60" autocomplete="off"/></div>' : '') +
          '<div class="cm-actions"><button type="button" class="btn-small cm-hold">' + esc(t('widgetHold')) + '</button><button type="button" class="btn-small btn-primary-small cm-record" disabled>' + esc(t('widgetRecord')) + '</button></div>' +
          '<div class="cm-status">&nbsp;</div>' +
        '</div></div>' +
        '<div class="cm-hint">' + esc(t('widgetDragHint')) + '</div>';

      var q = function (s) { return stage.querySelector(s); };
      var root = q('.cm'), view = q('.cm-view'), video = q('video'), demoSrc = q('canvas.cm-src');
      var boxes = { ref: q('.cm-box.ref'), meas: q('.cm-box.meas') };
      var swatch = q('.cm-swatch'), nums = [q('[data-ch="0"]'), q('[data-ch="1"]'), q('[data-ch="2"]')], hex = q('.cm-hex');
      var rawOut = q('[data-raw]'), refOut = q('[data-ref]'), warn = q('.cm-warn'), sampleInput = q('.cm-sample input');
      var setRefBtn = q('.cm-setref'), refNote = q('.cm-refnote'), holdBtn = q('.cm-hold'), recBtn = q('.cm-record'), status = q('.cm-status');
      var work = document.createElement('canvas'); work.width = work.height = SAMPLE_PX;
      var wctx = work.getContext('2d', { willReadFrequently: true });
      var stream = null, timer = null, held = false, hist = { ref: [], meas: [] }, cur = null, stopped = false, statusTimer = null, demoT = 0, drag = null;

      function say(msg, muted) {
        status.textContent = msg || ' '; status.classList.toggle('muted', !!muted);
        clearTimeout(statusTimer);
        if (msg) statusTimer = setTimeout(function () { if (status.textContent === msg) { status.textContent = ' '; refreshRecord(); } }, 4000);
      }
      function refreshRecord() {   // Record is disabled, with the reason shown, when the table cannot take another reading
        var can = ctx.canRecord ? ctx.canRecord() : { ok: false };
        recBtn.disabled = !can.ok || !cur;
        if (!can.ok && can.reason && !status.textContent.trim()) { status.textContent = can.reason; status.classList.add('muted'); }
      }
      function showRefState() {
        root.classList.toggle('uncorrected', !mem.base);
        setRefBtn.textContent = t(mem.base ? 'widgetResetRef' : 'widgetSetRef');
        refNote.textContent = mem.base ? ctx.fmt('widgetRefSetTo', { rgb: rgbText(mem.base) }) : t('widgetRefNotSet');
      }
      function setBase(from) { mem.base = (from || cur.ref).map(function (v) { return Math.round(v * 10) / 10; }); showRefState(); if (cur) show(cur); }
      setRefBtn.addEventListener('click', function () { if (!cur) return; setBase(); say(ctx.fmt('widgetRefSetTo', { rgb: rgbText(mem.base) })); });
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
          b.style.left = (g.ox + mem[k].x * s.w * g.scale) + 'px'; b.style.top = (g.oy + mem[k].y * s.h * g.scale) + 'px';
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
          mem[k] = clampPos(s, { x: (e.clientX - r.left - g.ox) / (s.w * g.scale), y: (e.clientY - r.top - g.oy) / (s.h * g.scale) });
          place(s);
        });
        var end = function () { if (!drag || drag.k !== k) return; drag = null; b.classList.remove('dragging'); hist = { ref: [], meas: [] }; };
        b.addEventListener('pointerup', end); b.addEventListener('pointercancel', end);
      });
      function drawDemo() {   // a bench, a grey card, a blue tube, and lighting that keeps changing: the corrected numbers stay put once the reference is set
        var c = demoSrc.getContext('2d'); demoT += 0.02;
        c.fillStyle = '#8f8a84'; c.fillRect(0, 0, 320, 240);
        c.fillStyle = '#c9c4bd'; c.fillRect(36, 68, 72, 104);
        c.fillStyle = 'rgb(38, 112, 186)'; c.fillRect(170, 56, 56, 128);
        c.fillStyle = 'hsla(' + ((demoT * 20) % 360) + ', 60%, 50%, ' + (0.22 + 0.18 * Math.sin(demoT)).toFixed(3) + ')'; c.fillRect(0, 0, 320, 240);
        c.fillStyle = 'rgba(255,255,255,0.85)'; c.font = '12px sans-serif'; c.fillText('sample picture: the light keeps changing', 10, 230);
      }
      function sampleAt(s, p, side) {
        wctx.drawImage(s.el, p.x * s.w - side / 2, p.y * s.h - side / 2, side, side, 0, 0, SAMPLE_PX, SAMPLE_PX);
        var d = wctx.getImageData(0, 0, SAMPLE_PX, SAMPLE_PX).data, n = d.length / 4, r = 0, g = 0, b = 0;
        for (var i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; }
        return [r / n, g / n, b / n];
      }
      function smooth(k, v) { var h = hist[k]; h.push(v); if (h.length > SMOOTH) h.shift(); return [0, 1, 2].map(function (i) { return h.reduce(function (a, x) { return a + x[i]; }, 0) / h.length; }); }
      function correct(raw, ref, base) { return raw.map(function (v, i) { return Math.max(0, Math.min(255, v * base[i] / Math.max(1, ref[i]))); }); }
      function show(c) {
        var out = mem.base ? correct(c.raw, c.ref, mem.base) : c.raw;
        var rgb = out.map(function (v) { return Math.round(v); });
        nums.forEach(function (el, i) { el.textContent = rgb[i]; });
        swatch.style.background = 'rgb(' + rgb.join(',') + ')';
        hex.textContent = '#' + rgb.map(function (v) { return ('0' + v.toString(16)).slice(-2); }).join('');
        rawOut.textContent = rgbText(c.raw); refOut.textContent = rgbText(c.ref);
        var clipped = c.ref.some(function (v) { return v >= 250; }), dark = c.ref.every(function (v) { return v < 25; });
        var drift = !!mem.base && c.ref.some(function (v, i) { return Math.abs(v / Math.max(1, mem.base[i]) - 1) > DRIFT; });
        warn.hidden = !(clipped || dark || drift);
        if (!warn.hidden) warn.textContent = t(clipped ? 'widgetRefClipped' : dark ? 'widgetRefDark' : 'widgetRefDrift');
      }
      function tick() {
        if (stopped) return;
        if (demoSrc) drawDemo();
        var s = source(); if (!s) return;
        place(s);
        if (held) return;
        var side = regionSide(s.w, s.h), ref, raw;
        try { ref = smooth('ref', sampleAt(s, mem.ref, side)); raw = smooth('meas', sampleAt(s, mem.meas, side)); } catch (e) { return; }
        var first = !cur; cur = { raw: raw, ref: ref }; show(cur);
        if (first) refreshRecord();
      }
      function toggleHold(v) {
        held = v == null ? !held : !!v;
        root.classList.toggle('held', held);
        holdBtn.textContent = t(held ? 'widgetResume' : 'widgetHold');
      }
      holdBtn.addEventListener('click', function () { toggleHold(); });
      recBtn.addEventListener('click', function () {
        if (!cur) return;
        var can = ctx.canRecord ? ctx.canRecord() : { ok: true };
        if (!can.ok) { say(can.reason, true); refreshRecord(); return; }
        if (!mem.base) setBase();   // a forgotten Set reference: the first reading defines the baseline
        var round = function (c) { return c.map(function (v) { return String(Math.round(v)); }); };
        var vals = round(correct(cur.raw, cur.ref, mem.base)); vals.also = { rawcolumns: round(cur.raw) }; vals.sample = sampleInput ? sampleInput.value.trim() : '';
        var r = null;
        try { r = ctx.record(vals); } catch (e) { r = { ok: false, reason: e && e.message }; }
        if (r && r.ok) {
          say(r.row ? ctx.fmt('widgetRecorded', { n: r.row }) : t('widgetRecord') + ' ✓');
          if (sampleInput) { sampleInput.value = ''; }
          if (held) toggleHold(false);
        } else say((r && r.reason) || t('widgetFailed'), true);
        refreshRecord();
      });
      function release() {
        clearInterval(timer); timer = null;
        if (stream) { try { stream.getTracks().forEach(function (tr) { tr.stop(); }); } catch (e) { /* ignore */ } stream = null; }
        if (video) { try { video.pause(); video.srcObject = null; } catch (e) { /* ignore */ } }
      }
      function loop() { if (stopped) return; clearInterval(timer); timer = setInterval(tick, PERIOD_MS); refreshRecord(); }
      function start() {
        showRefState();
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
      return { stop: function () { stopped = true; release(); mem.base = null; } };   // the reference dies with the run
    }
  };
})();
