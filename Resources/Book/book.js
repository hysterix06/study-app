// Study Tracker's book page: one chapter, read as a page or presented as slides. The app calls Book.render(payload)
// with a chapter it has already parsed (ChapterDoc.payload). Markdown goes through marked with raw HTML escaped and
// only http(s) links; maths (\( \), \[ \], $$ $$) through KaTeX with trust off. The only HTML taken as given is a
// figure's SVG, which the app drew itself or sanitised.
(function () {
  'use strict';
  const root = document.documentElement;
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  marked.use({
    gfm: true, breaks: false,
    renderer: {
      html(token) { return esc(token.text ?? token.raw ?? ''); },
      image(token) { return esc(token.text || ''); },
      link(token) {
        const text = this.parser.parseInline(token.tokens);
        return /^https?:\/\//i.test(token.href || '') ? '<a href="' + esc(token.href) + '">' + text + '</a>' : text;
      },
    },
  });

  function katexHTML(tex, display) {
    try { return katex.renderToString(tex, { displayMode: display, throwOnError: false, trust: false, strict: 'ignore', output: 'html' }); }
    catch (e) { return '<code>' + esc(tex) + '</code>'; }
  }

  // Maths comes out before marked sees it (marked would eat the backslashes). Code is held back first so maths
  // inside it stays literal. A lone $…$ counts only when it reads as TeX: "$120 and $80" stays money.
  function md(text, inline) {
    const held = [], maths = [];
    // Placeholders use private-use characters, which marked leaves alone.
    const hold = (m) => { held.push(m); return '\uE000' + (held.length - 1) + '\uE001'; };
    const math = (tex, display) => { maths.push(katexHTML(tex.trim(), display)); return '\uE002' + (maths.length - 1) + '\uE003'; };
    let s = String(text ?? '');
    s = s.replace(/```[\s\S]*?```|`[^`\n]+`/g, hold);
    s = s.replace(/\\\[([\s\S]+?)\\\]/g, (_, t) => math(t, true));
    s = s.replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => math(t, true));
    s = s.replace(/\\\(([\s\S]+?)\\\)/g, (_, t) => math(t, false));
    s = s.replace(/(^|[^\\$\w])\$(?![\s\d])([^$\n]*?[\\^_{}][^$\n]*?)(?<!\s)\$(?!\w)/g, (_, pre, t) => pre + math(t, false));
    s = s.replace(/\uE000(\d+)\uE001/g, (_, i) => held[Number(i)]);
    const html = inline ? marked.parseInline(s) : marked.parse(s);
    return html.replace(/\uE002(\d+)\uE003/g, (_, i) => maths[Number(i)]);
  }

  const boxLabels = { course: 'In your course', example: 'Example', note: 'Note', tip: 'Tip', warning: 'Watch out' };

  function block(b, inCheckSection) {
    switch (b.type) {
      case 'md': return '<div class="prose">' + md(b.md) + '</div>';
      case 'box': {
        if (b.kind === 'slide') return '';
        const label = boxLabels[b.kind] || 'Note';
        const title = b.title ? '<div class="box-title">' + md(b.title, true) + '</div>' : '';
        return '<aside class="box box-' + esc(b.kind) + '"><div class="label">' + label + '</div>' + title + md(b.md) + '</aside>';
      }
      case 'check': {
        const items = (b.items || []).map((qa) =>
          '<li><details><summary><span class="q">' + md(qa.q, true) + '</span></summary><div class="answer">' + md(qa.a) + '</div></details></li>').join('');
        return '<div class="check">' + (inCheckSection ? '' : '<div class="label">Check yourself</div>') + '<ol>' + items + '</ol></div>';
      }
      case 'figure':
        return '<figure class="fig">' + b.svg + (b.caption ? '<figcaption>' + esc(b.caption) + '</figcaption>' : '') + '</figure>';
      default: return '';
    }
  }

  let book = null;       // the payload being shown
  let slides = [];       // slide elements, built on first use
  let slide = 0;
  let presenting = false;
  let endArmed = false, endSent = false;

  function post(msg) {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.book;
    if (h) h.postMessage(msg);
  }

  function sectionNumber(p, i) { return p.number ? p.number + '.' + i : String(i); }

  function opener(p) {
    return '<header class="opener">' +
      (p.kicker ? '<div class="kicker">' + esc(p.kicker) + '</div>' : '') +
      (p.number ? '<div class="chapnum">' + esc(p.number) + '</div>' : '') +
      '<h1>' + md(p.title, true) + '</h1>' +
      (p.standfirst ? '<p class="standfirst">' + md(p.standfirst, true) + '</p>' : '') +
      '</header>';
  }

  const isCheckTitle = (t) => /check yourself|test yourself|self-check|review questions/i.test(t || '');

  function headHTML(p, s, n, isCheck) {
    return !s.title ? '' : '<h2>' + (isCheck ? '' : '<span class="secnum">' + esc(sectionNumber(p, n)) + '</span>') + md(s.title, true) + '</h2>';
  }

  function sectionHTML(p, s, i, n) {
    const isCheck = isCheckTitle(s.title);
    return '<section class="sec' + (s.title ? '' : ' intro') + (isCheck ? ' checks' : '') + '" data-i="' + i + '">' + headHTML(p, s, n, isCheck) +
      (s.blocks || []).map((b) => block(b, isCheck)).join('') + '</section>';
  }

  function render(p) {
    book = p;
    slides = []; slide = 0; endSent = false; endArmed = false;
    root.lang = p.lang || 'en';
    if (p.accent) {
      root.style.setProperty('--accent-light', p.accent.light);
      root.style.setProperty('--accent-dark', p.accent.dark);
    }
    root.classList.toggle('chrome', !!p.chrome);
    let n = 0;
    const sections = (p.sections || []).map((s, i) => sectionHTML(p, s, i, s.title ? ++n : n)).join('');
    // In the app, the end of the chapter says where its flashcards went.
    const note = p.cards && !p.chrome
      ? '<p class="end-note">This chapter’s ' + p.cards + ' flashcards are now in Review on Home.</p>' : '';
    document.getElementById('book').innerHTML = opener(p) + sections + '<div id="end">' + note + '</div>';
    document.getElementById('deck').innerHTML = '';
    sizeFigures(document.getElementById('book'));
    if (presenting) { buildSlides(); go(0); }
    requestAnimationFrame(() => restore(p.restore));
    if (document.fonts) document.fonts.ready.then(() => restore(p.restore));
  }

  // A drawing the model made is sized from its own viewBox, so a small sketch isn't blown up to the full column.
  function sizeFigures(scope) {
    scope.querySelectorAll('.fig svg:not(.diagram)').forEach((svg) => {
      const w = svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.width;
      if (w) svg.style.maxWidth = Math.round(Math.min(540, w * 1.3)) + 'px';
    });
  }

  // ---- Reading position ----------------------------------------------------------------------------------------

  function sectionEls() { return Array.from(document.querySelectorAll('#book .sec')); }

  function restore(r) {
    if (!r || presenting) return;
    const el = sectionEls()[r.section];
    if (!el) return;
    const top = el.getBoundingClientRect().top + window.scrollY + (r.fraction || 0) * el.offsetHeight;
    window.scrollTo(0, Math.max(0, top - 24));
  }

  function currentPosition() {
    const els = sectionEls();
    let i = 0;
    for (let k = 0; k < els.length; k++) if (els[k].getBoundingClientRect().top <= 80) i = k;
    const el = els[i];
    if (!el) return { section: 0, fraction: 0 };
    const r = el.getBoundingClientRect();
    return { section: i, fraction: Math.min(1, Math.max(0, (80 - r.top) / Math.max(1, r.height))) };
  }

  let lastPost = 0, pending = null;
  window.addEventListener('scroll', () => {
    endArmed = true;
    if (presenting) return;
    const now = Date.now();
    clearTimeout(pending);
    const send = () => { lastPost = Date.now(); post(Object.assign({ type: 'position' }, currentPosition())); };
    if (now - lastPost > 1000) send(); else pending = setTimeout(send, 1000);
    checkEnd();
  }, { passive: true });

  function checkEnd() {
    if (endSent || !endArmed) return;
    const end = document.getElementById('end');
    if (end && end.getBoundingClientRect().top < window.innerHeight) reachedEnd();
  }

  function reachedEnd() {
    if (endSent) return;
    endSent = true;
    post({ type: 'reachedEnd' });
  }

  // ---- Present ---------------------------------------------------------------------------------------------------

  // What a section shows when presented, as units never split across slides. A section with a :::slide summary
  // shows that, its figures, then its worked examples and course boxes; any other section shows everything,
  // paragraph by paragraph, a subheading kept with what follows it.
  function slideUnits(s, isCheck) {
    const blocks = s.blocks || [];
    const summary = blocks.filter((b) => b.type === 'box' && b.kind === 'slide');
    if (summary.length) {
      return summary.map((b) => '<div class="slide-points">' + md(b.md) + '</div>')
        .concat(blocks.filter((b) => b.type === 'figure').map((b) => block(b, isCheck)))
        .concat(blocks.filter((b) => b.type === 'box' && (b.kind === 'example' || b.kind === 'course')).map((b) => block(b, isCheck)));
    }
    const units = [];
    for (const b of blocks) {
      if (b.type !== 'md') { units.push(block(b, isCheck)); continue; }
      const holder = document.createElement('div');
      holder.innerHTML = md(b.md);
      let heads = '';
      for (const el of Array.from(holder.children)) {
        if (/^H[3-6]$/.test(el.tagName)) { heads += el.outerHTML; continue; }
        units.push('<div class="prose">' + heads + el.outerHTML + '</div>');
        heads = '';
      }
      if (heads) units.push('<div class="prose">' + heads + '</div>');
    }
    return units;
  }

  // Slides are filled unit by unit and measured, so a long section runs on to more slides instead of overflowing.
  function buildSlides() {
    const p = book;
    if (!p) return;
    const deck = document.getElementById('deck');
    deck.innerHTML = '<div class="deck-progress"><i></i></div><div class="deck-count"></div>';
    const ui = deck.firstChild;
    function newSlide(cls, i) {
      const el = document.createElement('section');
      el.className = 'slide measuring' + (cls ? ' ' + cls : '');
      if (i !== undefined) el.dataset.i = i;
      el.innerHTML = '<div class="slide-inner"></div>';
      deck.insertBefore(el, ui);
      return el;
    }
    const title = newSlide('title-slide');
    title.firstChild.innerHTML = opener(p);
    title.classList.remove('measuring');
    let n = 0;
    (p.sections || []).forEach((s, i) => {
      if (s.title) n++;
      const isCheck = isCheckTitle(s.title);
      let el = newSlide('', i);
      let inner = el.firstChild;
      inner.innerHTML = headHTML(p, s, n, isCheck);
      const style = getComputedStyle(el);
      const room = el.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
      let onSlide = 0;
      for (const html of slideUnits(s, isCheck)) {
        const holder = document.createElement('div');
        holder.innerHTML = html;
        const unit = holder.firstElementChild;
        if (!unit) continue;
        inner.appendChild(unit);
        sizeFigures(inner);
        if (onSlide > 0 && inner.scrollHeight > room) {
          inner.removeChild(unit);
          el.classList.remove('measuring');
          el = newSlide('more', i);
          inner = el.firstChild;
          if (s.title) inner.innerHTML = '<div class="more-label">' + (isCheck ? '' : esc(sectionNumber(p, n)) + ' · ') + md(s.title, true) + '</div>';
          inner.appendChild(unit);
          sizeFigures(inner);
          onSlide = 0;
        }
        onSlide++;
      }
      el.classList.remove('measuring');
    });
    slides = Array.from(deck.querySelectorAll('.slide'));
  }

  function firstSlideOf(section) {
    const k = slides.findIndex((el) => el.dataset.i === String(section));
    return k < 0 ? 0 : k;
  }

  function go(k) {
    if (!slides.length) return;
    slide = Math.max(0, Math.min(slides.length - 1, k));
    slides.forEach((el, i) => el.classList.toggle('active', i === slide));
    slides[slide].scrollTop = 0;
    document.querySelector('.deck-count').textContent = (slide + 1) + ' / ' + slides.length;
    document.querySelector('.deck-progress i').style.width = (100 * (slide + 1) / slides.length) + '%';
    if (slide === slides.length - 1) reachedEnd();
  }

  function present() {
    if (presenting) return;
    const pos = currentPosition();
    presenting = true;
    root.classList.add('present');
    buildSlides();
    // Start on the section being read (slide 0 is the title).
    go(window.scrollY < 40 ? 0 : firstSlideOf(pos.section));
    post({ type: 'mode', mode: 'present' });
  }

  function read() {
    if (!presenting) return;
    const el = slides[slide];
    presenting = false;
    root.classList.remove('present');
    const i = el && el.dataset.i ? Number(el.dataset.i) : -1;
    if (i >= 0) restore({ section: i, fraction: 0 }); else window.scrollTo(0, 0);
    post({ type: 'mode', mode: 'read' });
  }

  // Slides depend on the window's size, so a resize lays them out again on the same section.
  let relayout = null;
  window.addEventListener('resize', () => {
    if (!presenting) return;
    clearTimeout(relayout);
    relayout = setTimeout(() => {
      const i = slides[slide] && slides[slide].dataset.i;
      buildSlides();
      go(i === undefined ? 0 : firstSlideOf(Number(i)));
    }, 150);
  });

  // ---- Light and dark --------------------------------------------------------------------------------------------

  const dark = window.matchMedia('(prefers-color-scheme: dark)');
  let scheme = null; // null follows the system
  function applyScheme() { root.dataset.scheme = scheme || (dark.matches ? 'dark' : 'light'); }
  if (dark.addEventListener) dark.addEventListener('change', applyScheme);
  applyScheme();

  // ---- Keys and buttons ------------------------------------------------------------------------------------------

  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const k = e.key;
    if (presenting) {
      if (k === 'ArrowRight' || k === 'ArrowDown' || k === 'PageDown' || (k === ' ' && !e.shiftKey)) { go(slide + 1); e.preventDefault(); }
      else if (k === 'ArrowLeft' || k === 'ArrowUp' || k === 'PageUp' || (k === ' ' && e.shiftKey)) { go(slide - 1); e.preventDefault(); }
      else if (k === 'Home') { go(0); e.preventDefault(); }
      else if (k === 'End') { go(slides.length - 1); e.preventDefault(); }
      else if (k === 'Escape' || k === 'p' || k === 'P') { read(); e.preventDefault(); }
    } else if (k === 'p' || k === 'P') {
      present(); e.preventDefault();
    }
    if (root.classList.contains('chrome') && (k === 'd' || k === 'D')) {
      scheme = root.dataset.scheme === 'dark' ? 'light' : 'dark';
      applyScheme();
    }
  });

  document.addEventListener('click', (e) => {
    const t = e.target.closest && e.target.closest('[data-action]');
    if (!t) return;
    const a = t.dataset.action;
    if (a === 'present') present();
    else if (a === 'read') read();
    else if (a === 'scheme') { scheme = root.dataset.scheme === 'dark' ? 'light' : 'dark'; applyScheme(); }
  });

  window.Book = { render, present, read, md };
})();
