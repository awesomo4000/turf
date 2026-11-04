    (() => {
        const handler = HANDLER_NAME;
        const stateKey = STATE_KEY;
        if (window[stateKey]) return;
        const documentId = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
        let queue = [], dropped = 0, timer = null, stopped = false;
        const originals = [], listeners = [];
        function send(body) {
            if (window.chrome?.webview) {
                if (window !== top) parent.postMessage({turfDiagnostics: stateKey, body}, '*');
                else window.chrome.webview.postMessage(JSON.stringify({turfDiagnostics: stateKey, body}));
            } else window.webkit.messageHandlers[handler].postMessage(body);
        }

        let previewTruncated = false;
        function preview(value, seen = new WeakSet(), depth = 0) {
            try {
                if (typeof value === 'string') { if (value.length > 1000) previewTruncated = true; return value.slice(0, 1000); }
                if (value === null || typeof value === 'boolean') return value;
                if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
                if (typeof value === 'function') return '[Function]';
                if (typeof value !== 'object') {
                    const text = String(value); if (text.length > 1000) previewTruncated = true;
                    return text.slice(0, 1000);
                }
                if (seen.has(value)) { previewTruncated = true; return '[Circular]'; }
                if (depth >= 2) { previewTruncated = true; return '[Object]'; }
                seen.add(value);
                const result = Object.create(null);
                const keys = Object.keys(value); if (keys.length > 12) previewTruncated = true;
                for (const key of keys.slice(0, 12)) {
                    const d = Object.getOwnPropertyDescriptor(value, key);
                    if (key.length > 128) previewTruncated = true;
                    result[key.slice(0, 128)] = d && 'value' in d ? preview(d.value, seen, depth + 1) : '[Accessor]';
                }
                for (const key of ['name', 'message', 'stack']) {
                    const d = Object.getOwnPropertyDescriptor(value, key);
                    if (d && typeof d.value === 'string') {
                        if (d.value.length > 1000) previewTruncated = true;
                        result[key] = d.value.slice(0, 1000);
                    }
                }
                return result;
            } catch (_) { return '[Uninspectable]'; }
        }
        function flush() {
            timer = null;
            if (stopped) return;
            const batch = queue; queue = [];
            const loss = dropped; dropped = 0;
            try { send({documentId, entries: batch, dropped: loss, url: location.href.slice(0,2048), isMainFrame: window === top}); } catch (_) {}
        }
        function record(kind, level, values) {
            if (stopped) return;
            if (!window.chrome?.webview && !window.webkit?.messageHandlers?.[handler]) { window[stateKey]?.stop(); return; }
            previewTruncated = false;
            let args = values.slice(0, 8).map(v => preview(v));
            let entry = {kind, level, timestamp: Date.now(), args, truncated: previewTruncated || values.length > 8};
            if (JSON.stringify(entry).length > 4000) {
                entry.args = ['[Entry exceeded preview limit]']; entry.truncated = true;
            }
            if (queue.length === 64) { queue.shift(); dropped++; }
            queue.push(entry);
            if (timer === null) timer = setTimeout(flush, 0);
        }
        for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[level];
            const wrapper = function(...args) {
                try { record('console', level, args); } catch (_) {}
                return Reflect.apply(original, this, args);
            };
            try { console[level] = wrapper; originals.push([level, original, wrapper]); } catch (_) {}
        }
        function listen(type, callback) { window.addEventListener(type, callback); listeners.push([type, callback]); }
        listen('message', e => {
            if (e.data?.turfDiagnostics !== stateKey) return;
            if (e.data.stop && e.source === parent && window !== top) window[stateKey]?.stop();
            else if (e.data.body && window.chrome?.webview) send(e.data.body);
        });
        listen('pagehide', flush);
        listen('error', e => record('error', 'error', [e.message, e.error, {url: e.filename, line: e.lineno, column: e.colno}]));
        listen('unhandledrejection', e => record('unhandledrejection', 'error', [e.reason]));
        Object.defineProperty(window, stateKey, {configurable: true, value: {
            stop() {
                for (let i=0; i<frames.length; i++) frames[i].postMessage({turfDiagnostics: stateKey, stop:true}, '*');
                stopped = true; if (timer !== null) clearTimeout(timer);
                for (const [level, original, wrapper] of originals) if (console[level] === wrapper) console[level] = original;
                for (const [type, callback] of listeners) window.removeEventListener(type, callback);
                delete window[stateKey];
            }
        }});
        record('document', 'info', ['diagnostics attached']);
    })();
