// ==UserScript==
// @name         亚马逊极速秒开 & 一键火箭置顶 (可拖动)
// @namespace    https://github.com/xiaolin1991/vps-tools
// @version      1.5
// @description  彻底根治商品图片裂开问题 (自动转 m.media)；右侧边缘贴边火箭置顶按钮，支持上下自由拖动！
// @author       晓林技术支持
// @match        *://sellercentral.amazon.com/*
// @match        *://sellercentral-europe.amazon.com/*
// @match        *://sellercentral.amazon.co.uk/*
// @match        *://sellercentral.amazon.de/*
// @match        *://sellercentral.amazon.fr/*
// @match        *://sellercentral.amazon.it/*
// @match        *://sellercentral.amazon.es/*
// @match        *://sellercentral.amazon.co.jp/*
// @match        *://sellercentral.amazon.ca/*
// @match        *://sellercentral.amazon.com.mx/*
// @match        *://sellercentral.amazon.com.au/*
// @match        *://*.amazon.com/*
// @match        *://*.amazon.co.uk/*
// @match        *://*.amazon.de/*
// @match        *://*.amazon.co.jp/*
// @match        *://*.amazon.ca/*
// @match        *://*.amazon.com.mx/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    function replaceCdnUrl(url) {
        if (typeof url !== 'string') return url;
        if (url.includes('images-na.ssl-images-amazon.com') ||
            url.includes('images-fe.ssl-images-amazon.com') ||
            url.includes('images-eu.ssl-images-amazon.com')) {
            return url.replace(/(images-na|images-fe|images-eu)\.ssl-images-amazon\.com/g, 'm.media-amazon.com');
        }
        return url;
    }

    const originalSrc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    if (originalSrc && originalSrc.set) {
        Object.defineProperty(HTMLImageElement.prototype, 'src', {
            get: function() { return originalSrc.get.call(this); },
            set: function(val) { return originalSrc.set.call(this, replaceCdnUrl(val)); }
        });
    }

    const originalSrcset = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'srcset');
    if (originalSrcset && originalSrcset.set) {
        Object.defineProperty(HTMLImageElement.prototype, 'srcset', {
            get: function() { return originalSrcset.get.call(this); },
            set: function(val) { return originalSrcset.set.call(this, replaceCdnUrl(val)); }
        });
    }

    const origSetAttr = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function(name, value) {
        if (typeof value === 'string' && (name === 'src' || name === 'srcset' || name.startsWith('data-'))) {
            value = replaceCdnUrl(value);
        }
        return origSetAttr.call(this, name, value);
    };

    if (window.fetch) {
        const origFetch = window.fetch;
        window.fetch = function(input, init) {
            if (typeof input === 'string') {
                input = replaceCdnUrl(input);
            } else if (input instanceof Request && input.url) {
                const newUrl = replaceCdnUrl(input.url);
                if (newUrl !== input.url) input = new Request(newUrl, input);
            }
            return origFetch.call(this, input, init);
        };
    }

    const origXhrOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        if (typeof url === 'string') url = replaceCdnUrl(url);
        return origXhrOpen.call(this, method, url, ...rest);
    };

    function scanAndFix(node) {
        if (!node || node.nodeType !== 1) return;
        if (node.tagName === 'IMG') {
            if (node.src) node.src = replaceCdnUrl(node.src);
            if (node.srcset) node.srcset = replaceCdnUrl(node.srcset);
        } else if (node.querySelectorAll) {
            const imgs = node.querySelectorAll('img');
            for (let i = 0; i < imgs.length; i++) {
                if (imgs[i].src) imgs[i].src = replaceCdnUrl(imgs[i].src);
                if (imgs[i].srcset) imgs[i].srcset = replaceCdnUrl(imgs[i].srcset);
            }
        }
    }

    const observer = new MutationObserver(function(mutations) {
        for (let i = 0; i < mutations.length; i++) {
            const added = mutations[i].addedNodes;
            for (let j = 0; j < added.length; j++) scanAndFix(added[j]);
        }
    });

    function initRocketBtn() {
        if (document.getElementById('amz-rocket-top-btn')) return;

        const style = document.createElement('style');
        style.textContent = `
            #amz-rocket-top-btn {
                position: fixed !important;
                right: 0 !important;
                top: 70%;
                z-index: 2147483647 !important;
                width: 42px;
                height: 52px;
                background: linear-gradient(135deg, #FF9900 0%, #E65100 100%);
                border-radius: 12px 0 0 12px;
                box-shadow: -2px 4px 14px rgba(230, 81, 0, 0.45);
                cursor: grab;
                user-select: none;
                -webkit-user-select: none;
                display: flex;
                align-items: center;
                justify-content: center;
                transition: transform 0.2s cubic-bezier(0.2, 0, 0, 1), box-shadow 0.2s, opacity 0.3s;
                opacity: 0.85;
            }
            #amz-rocket-top-btn:hover {
                opacity: 1 !important;
                transform: translateX(-4px);
                box-shadow: -4px 6px 18px rgba(230, 81, 0, 0.65);
            }
            #amz-rocket-top-btn:active {
                cursor: grabbing !important;
            }
            .amz-rocket-box {
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                pointer-events: none;
            }
            .amz-rocket-icon {
                font-size: 21px;
                line-height: 1;
                filter: drop-shadow(0 2px 3px rgba(0,0,0,0.25));
                transition: transform 0.3s ease;
            }
            .amz-rocket-txt {
                font-size: 10px;
                font-weight: 800;
                color: #ffffff;
                margin-top: 2px;
                letter-spacing: 0.5px;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            }
            .amz-launching .amz-rocket-icon {
                animation: amzRocketBlast 0.6s ease-out forwards;
            }
            @keyframes amzRocketBlast {
                0% { transform: translateY(0) scale(1); }
                40% { transform: translateY(-8px) scale(1.25); }
                100% { transform: translateY(-45px) scale(0.5); opacity: 0; }
            }
        `;
        document.head.appendChild(style);

        const btn = document.createElement('div');
        btn.id = 'amz-rocket-top-btn';
        btn.title = '火箭置顶 (点击平滑置顶，按住可上下拖动)';
        btn.innerHTML = `
            <div class="amz-rocket-box">
                <span class="amz-rocket-icon">🚀</span>
                <span class="amz-rocket-txt">TOP</span>
            </div>
        `;

        try {
            const savedTop = localStorage.getItem('amz_rocket_top_y');
            if (savedTop) btn.style.top = savedTop;
        } catch(e) {}

        document.body.appendChild(btn);

        let isDragging = false, startY = 0, initialTop = 0, hasMoved = false;

        const handleStart = (clientY) => {
            isDragging = true;
            hasMoved = false;
            startY = clientY;
            initialTop = btn.getBoundingClientRect().top;
            btn.style.transition = 'none';
        };

        const handleMove = (clientY) => {
            if (!isDragging) return;
            const deltaY = clientY - startY;
            if (Math.abs(deltaY) > 4) hasMoved = true;
            let newTop = initialTop + deltaY;
            const minTop = 15;
            const maxTop = window.innerHeight - btn.offsetHeight - 15;
            if (newTop < minTop) newTop = minTop;
            if (newTop > maxTop) newTop = maxTop;
            btn.style.top = newTop + 'px';
        };

        const handleEnd = () => {
            if (!isDragging) return;
            isDragging = false;
            btn.style.transition = 'transform 0.2s cubic-bezier(0.2, 0, 0, 1), box-shadow 0.2s, opacity 0.3s';
            if (hasMoved) {
                try {
                    localStorage.setItem('amz_rocket_top_y', btn.style.top);
                } catch(e) {}
            }
        };

        btn.addEventListener('mousedown', function(e) {
            handleStart(e.clientY);
            const onMouseMove = (ev) => handleMove(ev.clientY);
            const onMouseUp = () => {
                handleEnd();
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
            };
            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
            e.preventDefault();
        });

        btn.addEventListener('touchstart', function(e) {
            if (e.touches.length > 0) handleStart(e.touches[0].clientY);
        }, { passive: true });

        btn.addEventListener('touchmove', function(e) {
            if (e.touches.length > 0) handleMove(e.touches[0].clientY);
        }, { passive: true });

        btn.addEventListener('touchend', handleEnd, { passive: true });

        btn.addEventListener('click', function(e) {
            if (hasMoved) return;
            btn.classList.add('amz-launching');
            window.scrollTo({ top: 0, behavior: 'smooth' });
            setTimeout(function() {
                btn.classList.remove('amz-launching');
            }, 600);
        });

        window.addEventListener('scroll', function() {
            if (window.scrollY < 120) {
                btn.style.opacity = '0.5';
            } else {
                btn.style.opacity = '0.85';
            }
        }, { passive: true });
    }

    if (document.documentElement) {
        observer.observe(document.documentElement, { childList: true, subtree: true });
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initRocketBtn);
    } else {
        initRocketBtn();
    }
})();
