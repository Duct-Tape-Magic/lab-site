/* Colorimeter widget for the Lab Site (see docs/WIDGETS.md).
   Loaded on demand by index.html the first time a student taps Start on a \widget[type=colorimeter] block, and registers
   window.LabWidgets.colorimeter = { mount(stage, ctx) → { stop } }.
   The host (index.html) owns Start/Stop, the idle/running/failed states, and the Record path into the lab's data table.
   This file only opens the camera (or draws a sample picture in demo mode), averages the centre square, and shows the readout.
   Nothing is stored or sent anywhere by this file; the pixels stay in the browser.
   ctx: { opts, demo, text(key), fmt(key, vars), canRecord() → {ok, reason}, record(values) → {ok, row | reason}, fail(why) }
   New version → new filename (colorimeter.v2.js) and update WIDGETS.colorimeter.file in index.html. */
(function () {
  'use strict';
  var W = window.LabWidgets = window.LabWidgets || {};
  var SMOOTH = 10;       // frames averaged so the numbers hold steady
  var PERIOD_MS = 100;   // about 10 readings a second
  var SAMPLE_PX = 16;    // the centre square is scaled down to this many pixels across before averaging
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  W.colorimeter = {
    mount: function (stage, ctx) {
      var opts = ctx.opts || {};
      var t = function (k) { return ctx.text(k); };
      stage.innerHTML = '<div class="cm">' +
        '<div class="cm-view">' + (ctx.demo ? '<canvas class="cm-src" width="320" height="240"></canvas>' : '<video playsinline muted autoplay></video>') + '<div class="cm-reticle"></div></div>' +
        '<div class="cm-side">' +
          '<div class="cm-swatch"></div>' +
          '<div class="cm-nums"><div class="cm-num"><b data-ch="0">–</b><span>R</span></div><div class="cm-num"><b data-ch="1">–</b><span>G</span></div><div class="cm-num"><b data-ch="2">–</b><span>B</span></div></div>' +
          '<div class="cm-hex">&nbsp;</div>' +
          (opts.sample ? '<div class="cm-sample"><label>' + esc(t('widgetSampleLabel')) + '</label><input type="text" maxlength="60" autocomplete="off"/></div>' : '') +
          '<div class="cm-actions"><button type="button" class="btn-small cm-hold">' + esc(t('widgetHold')) + '</button><button type="button" class="btn-small btn-primary-small cm-record" disabled>' + esc(t('widgetRecord')) + '</button></div>' +
          '<div class="cm-status">&nbsp;</div>' +
        '</div></div>';
      var q = function (s) { return stage.querySelector(s); };
      var root = q('.cm'), view = q('.cm-view'), video = q('video'), demoSrc = q('canvas.cm-src'), reticle = q('.cm-reticle');
      var swatch = q('.cm-swatch'), nums = [q('[data-ch="0"]'), q('[data-ch="1"]'), q('[data-ch="2"]')], hex = q('.cm-hex'), sampleInput = q('.cm-sample input');
      var holdBtn = q('.cm-hold'), recBtn = q('.cm-record'), status = q('.cm-status');
      var work = document.createElement('canvas'); work.width = work.height = SAMPLE_PX;
      var wctx = work.getContext('2d', { willReadFrequently: true });
      var stream = null, timer = null, held = false, hist = [], cur = null, stopped = false, statusTimer = null, demoT = 0;

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
      function source() {
        if (demoSrc) return { el: demoSrc, w: demoSrc.width, h: demoSrc.height };
        if (video && video.readyState >= 2 && video.videoWidth) return { el: video, w: video.videoWidth, h: video.videoHeight };
        return null;
      }
      function regionSide(w, h) {   // option region= in picture pixels; otherwise about 4% of the shorter side
        var r = parseInt(opts.region, 10);
        return r > 0 ? Math.min(r, w, h) : Math.max(8, Math.round(0.04 * Math.min(w, h)));
      }
      function drawDemo() {   // a slowly changing picture, so the demo shows live numbers without a camera
        var c = demoSrc.getContext('2d'); demoT += 0.02;
        var h1 = (demoT * 25) % 360;
        var g = c.createLinearGradient(0, 0, 320, 240); g.addColorStop(0, 'hsl(' + h1 + ', 55%, 85%)'); g.addColorStop(1, 'hsl(' + ((h1 + 60) % 360) + ', 45%, 60%)');
        c.fillStyle = g; c.fillRect(0, 0, 320, 240);
        c.fillStyle = 'hsl(' + ((h1 + 180) % 360) + ', 65%, ' + (45 + 10 * Math.sin(demoT)) + '%)';
        c.beginPath(); c.arc(160 + 18 * Math.sin(demoT * 0.7), 120 + 12 * Math.cos(demoT * 0.5), 46, 0, Math.PI * 2); c.fill();
        c.fillStyle = 'rgba(255,255,255,0.8)'; c.font = '12px sans-serif'; c.fillText('sample picture', 10, 230);
      }
      function show(c) {
        var rgb = c.map(function (v) { return Math.round(v); });
        nums.forEach(function (el, i) { el.textContent = rgb[i]; });
        swatch.style.background = 'rgb(' + rgb.join(',') + ')';
        hex.textContent = '#' + rgb.map(function (v) { return ('0' + v.toString(16)).slice(-2); }).join('');
      }
      function tick() {
        if (stopped) return;
        if (demoSrc) drawDemo();
        var s = source(); if (!s) return;
        var side = regionSide(s.w, s.h);
        var scale = Math.max(view.clientWidth / s.w, view.clientHeight / s.h) || 1;   // the picture is shown with object-fit: cover
        var px = Math.max(14, Math.round(side * scale)); reticle.style.width = reticle.style.height = px + 'px';   // the sampled square, never drawn smaller than a visible target
        if (held) return;
        try { wctx.drawImage(s.el, (s.w - side) / 2, (s.h - side) / 2, side, side, 0, 0, SAMPLE_PX, SAMPLE_PX); } catch (e) { return; }
        var d = wctx.getImageData(0, 0, SAMPLE_PX, SAMPLE_PX).data, n = d.length / 4, r = 0, g = 0, b = 0;
        for (var i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; }
        hist.push([r / n, g / n, b / n]); if (hist.length > SMOOTH) hist.shift();
        var avg = [0, 1, 2].map(function (k) { return hist.reduce(function (a, v) { return a + v[k]; }, 0) / hist.length; });
        var first = !cur; cur = avg; show(avg);
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
        var vals = cur.map(function (v) { return String(Math.round(v)); });
        vals.sample = sampleInput ? sampleInput.value.trim() : '';
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
      return { stop: function () { stopped = true; release(); } };
    }
  };
})();
