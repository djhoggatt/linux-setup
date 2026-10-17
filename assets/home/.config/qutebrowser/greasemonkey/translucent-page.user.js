// ==UserScript==
// @name         Translucent page surfaces
// @namespace    linux-setup
// @version      2
// @description  Clear large neutral page backgrounds, preserving controls and media.
// @match        http://*/*
// @match        https://*/*
// @run-at       document-end
// @grant        none
// ==/UserScript==
(() => {
    "use strict";
    const marker = "data-qute-translucent-surface";
    const selector = "div,main,section,article,header,footer,nav,aside";
    const protectedArea = "dialog,[role=dialog],[aria-modal=true],[role=menu],[role=listbox],button,input,select,textarea,video,canvas";
    function scan() {
        // Disconnect while changing attributes to avoid observing our own writes.
        observer.disconnect();
        document.querySelectorAll(selector).forEach(element => {
            element.removeAttribute(marker);
            if (element.closest(protectedArea)) return;
            const rect = element.getBoundingClientRect();
            if (rect.width < innerWidth * 0.45 || rect.height < 80 ||
                rect.width * rect.height < innerWidth * innerHeight * 0.12) return;
            const style = getComputedStyle(element);
            if (style.backgroundImage !== "none" || style.position === "fixed" ||
                style.position === "sticky") return;
            const rgb = style.backgroundColor.match(/^rgba?\(([^)]+)\)$/);
            if (!rgb) return;
            const values = rgb[1].split(",").map(Number);
            const [r, g, b, alpha = 1] = values;
            // Keep colorful panels and intentionally translucent overlays intact.
            if (alpha < 0.95 || Math.max(r, g, b) - Math.min(r, g, b) > 40) return;
            element.setAttribute(marker, "");
        });
        observer.observe(document.documentElement, {
            subtree: true, childList: true, attributes: true,
            attributeFilter: ["class", "style", "hidden"]
        });
    }
    let timer;
    function schedule() {
        if (timer) return;
        timer = setTimeout(() => { timer = null; scan(); }, 250);
    }
    const observer = new MutationObserver(schedule);
    addEventListener("resize", schedule);
    addEventListener("load", schedule);
    scan();
})();
