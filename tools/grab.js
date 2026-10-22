// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
// Called by turf-client.py with a unique token and a URL or JavaScript expression.
(async (token, source) => {
    const state = { blob: null, timer: null };
    window[token] = state;
    const expire = () => { if (window[token] === state) delete window[token]; };
    state.refresh = () => {
        clearTimeout(state.timer);
        state.timer = setTimeout(expire, 120000);
    };
    state.refresh();
    let operationTimer;
    try {
        const load = async () => {
            let value = /^(https?:|blob:|data:)/i.test(source) ? source : await (0, eval)(source);
            if (typeof value === 'string' && /^(https?:|blob:)/i.test(value)) {
                const response = await fetch(value, {signal: AbortSignal.timeout(20000)});
                if (!response.ok) throw new Error(`HTTP ${response.status}`);
                value = await response.blob();
            }
            if (typeof value === 'string') {
                let mime = 'application/octet-stream';
                if (value.startsWith('data:')) {
                    const match = /^data:([^;,]*)(;base64)?,([\s\S]*)$/.exec(value);
                    if (!match) throw new Error('Unsupported data URI');
                    mime = match[1] || 'text/plain';
                    if (!match[2]) return new Blob([decodeURIComponent(match[3])], {type: mime});
                    value = match[3];
                }
                const binary = atob(value);
                return new Blob([Uint8Array.from(binary, char => char.charCodeAt(0))], {type: mime});
            }
            if (value instanceof Blob) return value;
            if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return new Blob([value]);
            throw new Error('grab expects a URL, base64/data URI, Blob, ArrayBuffer, or typed array');
        };
        const blob = await Promise.race([
            load(),
            new Promise((_, reject) => { operationTimer = setTimeout(() => reject(new Error('grab preparation timed out')), 25000); })
        ]);
        if (window[token] !== state) throw new Error('grab state expired');
        state.blob = blob;
        return {bytes: blob.size, mime: blob.type || 'application/octet-stream'};
    } catch (error) {
        clearTimeout(state.timer);
        expire();
        throw error;
    } finally {
        clearTimeout(operationTimer);
    }
})
