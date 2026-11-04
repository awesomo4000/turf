    function describe(value, kind) {
        function text(v, fallback, limit = 4096) {
            const chosen = typeof v === 'string' ? v : fallback;
            return typeof chosen === 'string' ? chosen.slice(0, limit) : chosen;
        }
        function field(key) {
            try {
                let object = value;
                for (let i = 0; object != null && i < 5; i++, object = Object.getPrototypeOf(object)) {
                    const d = Object.getOwnPropertyDescriptor(object, key);
                    if (d) return 'value' in d ? d.value : undefined;
                }
            } catch (_) {}
        }
        const type = value === null ? 'null' : typeof value;
        const primitive = !['object', 'function'].includes(type);
        let message = primitive ? String(value) : 'Thrown ' + type;
        const line = field('line'), column = field('column');
        return {kind, name: text(field('name'), primitive ? 'ThrownValue' : 'Error', 128),
                message: text(field('message'), message),
                stack: text(field('stack'), null), sourceURL: text(field('sourceURL'), null, 2048),
                line: typeof line === 'number' && Number.isFinite(line) ? line : null,
                column: typeof column === 'number' && Number.isFinite(column) ? column : null,
                context: 'main', thrownType: type};
    }
    let value;
    try {
        value = await (0, eval)(expression + '\n//# sourceURL=turf-evaluate.js');
    } catch (error) {
        return JSON.stringify({ok: false, error: describe(error, 'javascript_exception')});
    }
    try {
        return JSON.stringify({ok: true, result: {type: value === null ? 'null' : typeof value, value}});
    } catch (error) {
        return JSON.stringify({ok: false, error: describe(error, 'serialization_error')});
    }
