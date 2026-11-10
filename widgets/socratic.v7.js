/* Socratic tutor widget for the Lab Site (docs/SOCRATIC.md, docs/WIDGETS.md).
   Loaded on demand the first time a signed-in student taps Start on a \widget[type=socratic, bank=…] block, and registers
   window.LabWidgets.socratic = { mount(stage, ctx) → { stop } }.
   The host (index.html) owns Start/Stop and the idle/running/failed states. This file draws the conversation and talks to the
   site's server function through ctx.call(payload, onDelta): resume → start → turn … → end. The server holds the problem bank,
   the prompt and the API key; this file keeps nothing of its own (no localStorage) and sends nothing anywhere else.
   Bare on purpose: the conversation, a text box, Send, End session, Skip this problem, Report a problem (a small box that sends a
   note to the teacher), one progress line, and a warning line when the owner's weekly allowance is running low. Text only.
   (v2: the I'm stuck button is gone; students say so in their own words. v3: Skip and Report a problem. v4: progress is counted in topics credited, not problems. v5: everything under the conversation sits in one .soc-dock, so the host's full-page layout can pin it to the bottom. v6: a block with no bank says so in its own words.)
   ctx: { opts, labId, text(key), fmt(key, vars), call(payload, onDelta) → Promise, renderMath(node), updated(), fail(why) }
   v7: the answer box takes the cursor only when no other field has it.
   New version → new filename (socratic.v8.js) and update WIDGETS.socratic.file in index.html. */
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
        '<div class="soc-dock">' +
        '<div class="soc-warn" data-role="warn" hidden></div>' +
        '<div class="soc-note" data-role="note" hidden></div>' +
        '<div class="soc-input"><textarea rows="2" data-role="input" placeholder="' + esc(t('socPlaceholder')) + '"></textarea><button type="button" class="btn-small btn-primary-small" data-role="send">' + esc(t('socSend')) + '</button></div>' +
        '<div class="soc-foot"><button type="button" class="btn-small" data-role="end">' + esc(t('socEnd')) + '</button><button type="button" class="btn-small" data-role="skip">' + esc(t('socSkip')) + '</button><button type="button" class="btn-small" data-role="report">' + esc(t('socReportButton')) + '</button><button type="button" class="btn-small" data-role="again" hidden>' + esc(t('socAgain')) + '</button><span class="soc-progress" data-role="progress"></span></div>' +
        '<div class="soc-report" data-role="reportbox" hidden><div class="soc-note">' + esc(t('socReportIntro')) + '</div><textarea rows="3" maxlength="2000" data-role="reporttext" placeholder="' + esc(t('socReportPlaceholder')) + '"></textarea><div class="soc-report-actions"><button type="button" class="btn-small btn-primary-small" data-role="reportsend">' + esc(t('socReportSend')) + '</button><span class="soc-note" data-role="reportstatus"></span></div></div>' +
        '</div>' +   /* .soc-dock */
        '</div>';
      var q = function (r) { return stage.querySelector('[data-role="' + r + '"]'); };
      var log = q('log'), input = q('input'), note = q('note'), warn = q('warn');

      function setNote(text, cls) { if (!text) { note.hidden = true; return; } note.className = cls || 'soc-note'; note.textContent = text; note.hidden = false; }
      function setWarn(text) { if (!text) { warn.hidden = true; return; } warn.textContent = text; warn.hidden = false; }
      function setBusy(b) { busy = b; input.disabled = b || limited || !session || !!(session && session.ended); q('send').disabled = input.disabled; q('end').disabled = b || !session || !!(session && session.ended); q('skip').disabled = input.disabled; q('report').disabled = !session; }
      function progress() {   // topics credited out of the bank's topics; the problem count is detail. The bank is a pool, never a set to finish.
        var p = session && session.progress; if (!p) { q('progress').textContent = ''; return; }
        total = p.topics_total || total; if (box && total) box.dataset.socTotal = String(total);
        q('progress').textContent = ctx.fmt('socProgress', { topics: p.topics || 0, total: total, posed: p.posed, credited: p.credited });
        if (p.all_done && !(session && session.ended)) setNote(t('socAllDone'), 'soc-ok');
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
      function focusFree() { var a = document.activeElement; return !a || a === document.body || stage.contains(a); }   // never take the cursor from another field the person is typing in
      function afterTurn(ended) {
        q('again').hidden = !ended; q('end').hidden = !!ended; q('skip').hidden = !!ended; input.parentElement.hidden = !!ended;
        if (ended) setNote(t('socEnded'), 'soc-ok');
        setBusy(false); if (!ended && !limited && focusFree()) input.focus({ preventScroll: true });
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
        if (!bank) { setNote(t('socNoBank')); setBusy(true); return; }   // the Builder warns about this; the words here are the tutor's own, not the table-widget note
        setBusy(true); setNote(t('socThinking'));
        ctx.call({ action: 'resume', bank_id: bank }).then(function (res) {
          if (stopped) return;
          total = res.topics_total || 0; if (box && total) box.dataset.socTotal = String(total);
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
      q('skip').addEventListener('click', function () {   // gives up the problem in play; the server records it as skipped and the tutor moves on
        if (busy || !session || session.ended || limited) return;
        setBusy(true); setNote('');
        streamed({ action: 'skip', session_id: session.id }).then(function (r) { if (r && !r.limit) afterTurn(session && session.ended); }).catch(function () {});
      });
      var rbox = q('reportbox'), rtext = q('reporttext'), rstatus = q('reportstatus');
      q('report').addEventListener('click', function () { rbox.hidden = !rbox.hidden; rstatus.textContent = ''; rstatus.className = 'soc-note'; if (!rbox.hidden) rtext.focus({ preventScroll: true }); });
      q('reportsend').addEventListener('click', function () {   // a note to the teacher about this problem; stored with the session and posted to the lab's help thread
        var note = String(rtext.value || '').trim(); if (!note || !session) { rtext.focus(); return; }
        q('reportsend').disabled = true; rstatus.textContent = '…'; rstatus.className = 'soc-note';
        ctx.call({ action: 'report', session_id: session.id, note: note }).then(function () {
          rtext.value = ''; rstatus.textContent = t('socReportSent'); rstatus.className = 'soc-ok'; q('reportsend').disabled = false;
        }, function () { rstatus.textContent = t('socReportError'); rstatus.className = 'soc-warn'; q('reportsend').disabled = false; });
      });
      q('again').addEventListener('click', function () { if (busy) return; q('again').hidden = true; input.parentElement.hidden = false; q('end').hidden = false; q('skip').hidden = false; setNote(''); session = null; boot(); });

      setBusy(true); boot();
      return { stop: function () { stopped = true; } };
    },
  };
})();
