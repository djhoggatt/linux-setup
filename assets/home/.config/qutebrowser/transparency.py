"""Keep transparent WebEngine pages below completions and link hints.

Qt gives transparent WebEngine views priority over ordinary child widgets.
Temporarily use an opaque page while an overlay is visible. Reference counts
allow hints and completions to overlap without restoring transparency early.
"""
from weakref import WeakKeyDictionary

from qutebrowser.browser.hints import HintLabel
from qutebrowser.completion.completionwidget import CompletionView
from qutebrowser.qt.core import Qt
from qutebrowser.qt.gui import QColor
from qutebrowser.qt.widgets import QLabel
from qutebrowser.qt.webenginewidgets import QWebEngineView


def install():
    # Restart after upgrading this helper; repeated config-source is harmless.
    if getattr(CompletionView, "_transparency_workaround", False):
        return
    pages = WeakKeyDictionary()

    def acquire(owner):
        if getattr(owner, "_transparency_pages", None):
            return
        owner._transparency_pages = []
        for view in owner.window().findChildren(QWebEngineView):
            page = view.page()
            if page in pages:
                pages[page][1] += 1
            else:
                color = page.backgroundColor()
                if color.alpha() == 255:
                    continue
                pages[page] = [color, 1]
                page.setBackgroundColor(QColor("#141418"))
            owner._transparency_pages.append(page)
        owner.window().update()

    def release(owner):
        for page in getattr(owner, "_transparency_pages", []):
            state = pages.get(page)
            if state is None:
                continue
            state[1] -= 1
            if state[1] == 0:
                try:
                    page.setBackgroundColor(state[0])
                except RuntimeError:
                    pass  # The tab may have closed with an overlay visible.
                del pages[page]
        owner._transparency_pages = []
        owner.window().update()

    def wrap_visibility(cls):
        original_show = cls.showEvent
        original_hide = cls.hideEvent

        def show(self, event):
            acquire(self)
            original_show(self, event)

        def hide(self, event):
            original_hide(self, event)
            release(self)

        cls.showEvent = show
        cls.hideEvent = hide

    # Use the upstream child-label initialization, also on installations whose
    # hints.py was patched by the retired tooltip-window workaround. The
    # existing positioning method already handles child-relative coordinates.
    def hint_init(self, elem, context):
        QLabel.__init__(self, parent=context.tab)
        self._context = context
        self.elem = elem
        self.setTextFormat(Qt.TextFormat.RichText)
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        self.setIndent(0)
        self._context.tab.contents_size_changed.connect(self._move_to_elem)
        self._move_to_elem()
        self.show()

    HintLabel.__init__ = hint_init
    wrap_visibility(CompletionView)
    wrap_visibility(HintLabel)
    CompletionView._transparency_workaround = True


install()
