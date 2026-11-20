// Fades each block in as it scrolls into view. Without IntersectionObserver everything is simply shown.
(function () {
  var blocks = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window)) {
    blocks.forEach(function (el) { el.classList.add('in'); });
    return;
  }
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('in');
      observer.unobserve(entry.target);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  blocks.forEach(function (el) { observer.observe(el); });
})();
