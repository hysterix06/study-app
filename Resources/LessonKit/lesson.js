// Study Tracker's lesson and notebook renderer. The app calls StudyKit.render({theme, blocks}). Markdown goes through
// marked with raw HTML escaped; maths ($…$, $$…$$) through KaTeX with trust off; drawings arrive already sanitised.
(function () {
  'use strict';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  marked.use({
    gfm: true, breaks: false,
    renderer: {
      html(token) { return esc(token.text ?? token.raw ?? ''); },
      image(token) { return esc(token.text || ''); },
    },
  });

  function katexHTML(tex, display) {
    try { return katex.renderToString(tex, { displayMode: display, throwOnError: false, trust: false, strict: 'ignore', output: 'html' }); }
    catch (e) { return '<code>' + esc(tex) + '</code>'; }
  }

  // Maths first, so marked never sees it: $$display$$, then $inline$ (not "$5 and $10").
  function md(text, inline) {
    const maths = [];
    let s = String(text ?? '');
    s = s.replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => { maths.push(katexHTML(t.trim(), true)); return '@@M' + (maths.length - 1) + '@@'; });
    s = s.replace(/(^|[^\\$])\$(?!\s)([^$\n]+?)(?<!\s)\$(?!\d)/g, (_, pre, t) => { maths.push(katexHTML(t, false)); return pre + '@@M' + (maths.length - 1) + '@@'; });
    let html = inline ? marked.parseInline(s) : marked.parse(s);
    return html.replace(/@@M(\d+)@@/g, (_, i) => maths[Number(i)]);
  }

  function page(b) {
    const out = ['<section class="page">', '<div class="page-head">'];
    if (b.number) out.push('<span class="num">' + esc(b.number) + '</span>');
    out.push('<span class="title">' + esc(b.title) + '</span>');
    if (b.mark) out.push('<span class="mark">' + esc(b.mark) + '</span>');
    if (b.action) out.push('<button class="act" data-name="' + esc(b.action.name) + '" data-id="' + esc(b.action.id) + '">' + esc(b.action.label) + '</button>');
    out.push('</div>');
    const terms = b.terms || [], pictures = b.diagrams || [], formulas = b.formulas || [];
    if (!terms.length && !pictures.length && !formulas.length) out.push('<p class="pending">' + esc(b.pending || 'This page is still being written.') + '</p>');
    if (terms.length) {
      out.push('<h4>Words</h4>');
      for (const t of terms) {
        out.push('<div class="term"><b>' + esc(t.term) + '</b>' + (t.definition ? ' — ' + md(t.definition, true) : '') + '</div>');
        if (t.wording) out.push('<div class="wording">Your course: “' + md(t.wording, true) + '”' + (t.locator ? ' <span class="src">(' + esc(t.locator) + ')</span>' : '') + '</div>');
      }
    }
    if (pictures.length) {
      out.push('<h4>Pictures</h4>');
      for (const d of pictures) {
        out.push('<div class="picture"><div class="ptitle">' + esc(d.title) + '</div>');
        if (d.svg) out.push('<div class="drawing" role="img" aria-label="' + esc(d.title) + '">' + d.svg + '</div>');
        if (d.draw) out.push('<div class="draw">Draw: ' + md(d.draw, true) + '</div>');
        if (d.labels && d.labels.length) out.push('<div class="labels">Label: ' + d.labels.map(esc).join(', ') + '</div>');
        out.push('</div>');
      }
    }
    if (formulas.length) {
      out.push('<h4>Formulas</h4>');
      for (const f of formulas) out.push('<div class="formula">' + katexHTML(f.latex, true) + (f.meaning ? '<div class="meaning">' + md(f.meaning, true) + '</div>' : '') + '</div>');
    }
    if (b.links && b.links.length) out.push('<div class="links">' + b.links.map(esc).join(' &nbsp; ') + '</div>');
    out.push('</section>');
    return out.join('');
  }

  const sectionLabels = { idea: 'The idea · general knowledge', example: 'Worked example · general knowledge', course_angle: 'Your course’s angle',
                          mistakes: 'Common mistakes', summary: 'In short' };

  function block(b) {
    switch (b.type) {
      case 'markdown': return '<div class="' + esc(b.cls || '') + '">' + md(b.md) + '</div>';
      case 'divider': return '<div class="divider">' + esc(b.text) + '</div>';
      case 'question': return '<div class="question">' + md(b.text, true) + '</div>';
      case 'page': return page(b);
      case 'section': {
        let label = sectionLabels[b.kind] || '';
        if (b.kind === 'course_angle' && b.sources && b.sources.length) label += ' · ' + b.sources.map(esc).join(', ');
        return '<section class="section ' + esc(b.kind) + '"><div class="label">' + label + '</div>' + (b.title && !/^(the idea|worked example|in short|common mistakes|your course.s angle)$/i.test(b.title) ? '<h3>' + esc(b.title) + '</h3>' : '') + md(b.md) + '</section>';
      }
      default: return '';
    }
  }

  function applyTheme(theme) {
    const root = document.documentElement.style;
    for (const [k, v] of Object.entries(theme || {})) root.setProperty('--' + k, v);
  }

  function reportSize() {
    const h = Math.ceil(document.getElementById('root').getBoundingClientRect().height) + 4;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.size) window.webkit.messageHandlers.size.postMessage(h);
  }

  window.StudyKit = {
    render(payload) {
      applyTheme(payload.theme);
      document.getElementById('root').innerHTML = (payload.blocks || []).map(block).join('');
      reportSize();
      if (document.fonts) document.fonts.ready.then(reportSize);
    },
    md,
  };
  // Buttons on a page (Mark written) go back to the app.
  document.addEventListener('click', (e) => {
    const b = e.target.closest && e.target.closest('button.act');
    if (!b || !(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.action)) return;
    window.webkit.messageHandlers.action.postMessage({ name: b.dataset.name, id: Number(b.dataset.id) });
  });
  window.addEventListener('resize', reportSize);
  if (window.ResizeObserver) new ResizeObserver(reportSize).observe(document.documentElement);
})();
