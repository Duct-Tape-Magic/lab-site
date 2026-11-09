/* Socratic tutor widget for the Lab Site (docs/SOCRATIC.md, docs/WIDGETS.md).
   Loaded on demand the first time a signed-in student taps Start on a \widget[type=socratic, bank=…] block, and registers
   window.LabWidgets.socratic = { mount(stage, ctx) → { stop } }.
   The host (index.html) owns Start/Stop and the idle/running/failed states. This file draws the conversation and talks to the
   site's server function through ctx.call(payload, onDelta): resume → start → turn … → end. The server holds the problem bank,
   the prompt and the API key; this file keeps nothing of its own (no localStorage) and sends nothing anywhere else.
   Bare on purpose: the conversation, a text box, Send, End session, one progress line, and a warning line when the owner's
   weekly allowance is running low. Text only in this version. (v2: the I'm stuck button is gone; students say so in their own words.)
   ctx: { opts, labId, text(key), fmt(key, vars), call(payload, onDelta) → Promise, renderMath(node), updated(), fail(why) }
   New version → new filename (socratic.v3.js) and update WIDGETS.socratic.file in index.html. */
(function () {
  'use strict';
  var W = window.LabWidgets = window.LabWidgets || {};
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function el(html) { var d = document.createElement('div'); d.innerHTML = html; return d.firstElementChild; }

  W.socratic = {
    mount: function (stage, ctx) {
      var opts = ctx.opts || {}, t = function (k) { return ctx.text(k); };
      var bank = String(opts.bank || '').trim();
      var session = null, total = 0, busy = false, stopped = false, limited = false;
      var box = stage.closest('.lt-widget');

      stage.innerHTML = '<div class="soc">' +
        '<div class="soc-log" data-role="log"></div>' +
        '<div class="soc-warn" data-role="warn" hidden></div>' +
        '<div class="soc-note" data-role="note" hidden></div>' +
        '<div class="soc-input"><textarea rows="2" data-role="input" placeholder="' + esc(t('socPlaceholder')) + '"></textarea><button type="button" class="btn-small btn-primary-small" data-role="send">' + esc(t('socSend')) + '</button></div>' +
        '<div class="soc-foot"><button type="button" class="btn-small" data-role="end">' + esc(t('socEnd')) + '</button><button type="button" class="btn-small" data-role="again" hidden>' + esc(t('socAgain')) + '</button><span class="soc-progress" data-role="progress"></span></div>' +
        '</div>';
      var q = function (r) { return stage.querySelector('[data-role="' + r + '"]'); };
      var log = q('log'), input = q('input'), note = q('note'), warn = q('warn');

      function setNote(text, cls) { if (!text) { note.hidden = true; return; } note.className = cls || 'soc-note'; note.textContent = text; note.hidden = false; }
      function setWarn(text) { if (!text) { warn.hidden = true; return; } warn.textContent = text; warn.hidden = false; }
      function setBusy(b) { busy = b; input.disabled = b || limited || !session || !!(session && session.ended); q('send').disabled = input.disabled; q('end').disabled = b || !session || !!(session && session.ended); }
      function progress() {
        var p = session && session.progress; if (!p) { q('progress').textContent = ''; return; }
        total = p.total || total; if (box && total) box.dataset.socTotal = String(total);
        q('progress').textContent = ctx.fmt('socProgress', { posed: p.posed, total: total, credited: p.credited });
      }
      function bubble(role, text, pending) {
        var b = el('<div class="soc-msg ' + (role === 'assistant' ? 'tutor' : 'me') + (pending ? ' pending' : '') + '"></div>');
        b.textContent = text || ''; log.appendChild(b); log.scrollTop = log.scrollHeight; return b;
      }
      function finish(b, text) { b.classList.remove('pending'); b.textContent = text || ''; try { ctx.renderMath(b); } catch (e) { /* ignore */ } log.scrollTop = log.scrollHeight; }
      function hidePartialState(s) { return String(s || '').replace(/\s*<<[\s\S]*$/, ''); }   // the hidden state line may be half-streamed
      function renderSession(s) {
        session = s; log.innerHTML = '';
        (s.messages || []).forEach(function (m) { finish(bubble(m.role, ''), m.text); });
        if (s.ended && s.summary && !(s.messages || []).some(function (m) { return m.role === 'assistant' && m.text === s.summary; })) finish(bubble('assistant', ''), s.summary);
        progress(); afterTurn(s.ended);
      }
      function afterTurn(ended) {
        q('again').hidden = !ended; q('end').hidden = !!ended; input.parentElement.hidden = !!ended;
        if (ended) setNote(t('socEnded'), 'soc-ok');
        setBusy(false); if (!ended && !limited) input.focus({ preventScroll: true });
      }
      function applyMeta(res) {
        if (!res) return;
        if (res.limit === 'limit') { limited = true; setNote(t('socLimit')); setWarn(''); setBusy(false); return true; }
        if (res.limit === 'site-limit') { limited = true; setNote(t('socSiteLimit')); setWarn(''); setBusy(false); return true; }
        setWarn(res.warn || '');
        return false;
      }

      function streamed(payload) {
        var pending = bubble('assistant', t('socThinking'), true), raw = '';
        return ctx.call(payload, function (delta) { raw += delta; pending.textContent = hidePartialState(raw) || t('socThinking'); log.scrollTop = log.scrollHeight; })
          .then(function (res) {
            if (stopped) return res;
            if (res && res.limit) { pending.remove(); applyMeta(res); return res; }
            finish(pending, res && res.message ? res.message.text : hidePartialState(raw));
            if (res && res.session) session = res.session;
            progress(); applyMeta(res); try { ctx.updated(); } catch (e) { /* ignore */ }
            return res;
          }, function (e) { pending.remove(); setNote(t('socError')); setBusy(false); throw e; });
      }

      function boot() {
        if (!bank) { setNote(t('widgetUnavailable')); setBusy(true); return; }
        setBusy(true); setNote(t('socThinking'));
        ctx.call({ action: 'resume', bank_id: bank }).then(function (res) {
          if (stopped) return;
          total = res.total || 0; if (box && total) box.dataset.socTotal = String(total);
          if (applyMeta(res)) return;
          setNote('');
          if (res.session) { renderSession(res.session); return; }
          return streamed({ action: 'start', bank_id: bank }).then(function (r) { if (r && r.session) afterTurn(false); });
        }).catch(function (e) { if (!stopped) { setNote(t('socError')); setBusy(false); ctx.fail && ctx.fail('failed'); } });
      }
      function send(text) {
        text = String(text || '').trim(); if (!text || busy || !session || session.ended || limited) return;
        bubble('user', text); input.value = ''; setBusy(true); setNote('');
        streamed({ action: 'turn', session_id: session.id, text: text }).then(function (r) { if (r && !r.limit) afterTurn(session && session.ended); }).catch(function () {});
      }
      q('send').addEventListener('click', function () { send(input.value); });
      input.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(input.value); } });
      q('end').addEventListener('click', function () {
        if (busy || !session || session.ended) return;
        setBusy(true); setNote('');
        streamed({ action: 'end', session_id: session.id }).then(function (r) { if (r && r.session) { session = r.session; afterTurn(true); } }).catch(function () {});
      });
      q('again').addEventListener('click', function () { if (busy) return; q('again').hidden = true; input.parentElement.hidden = false; q('end').hidden = false; setNote(''); session = null; boot(); });

      setBusy(true); boot();
      return { stop: function () { stopped = true; } };
    },
  };
})();
