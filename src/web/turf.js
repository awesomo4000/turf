// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

// This script is injected into the webview when the window is created.
// It provides the turf API for communication between JavaScript and native code.

(function() {
    // Registry dictionary to store the handlers for messages
    const registry = {};

    // Send a message to the native application
    function send(message) {
        if (window.webkit &&
            window.webkit.messageHandlers &&
            window.webkit.messageHandlers.__turf__) {
            // Create a properly formatted message
            const formattedMessage = {
                type: message.type
            };
            
            // Add data fields directly to the message object
            if (message.data) {
                // If data is an object, spread its properties into the message
                if (typeof message.data === 'object' && message.data !== null) {
                    Object.assign(formattedMessage, message.data);
                } else {
                    // Otherwise add it as a message field
                    formattedMessage.message = message.data;
                }
            }
            
            const jsonMessage = JSON.stringify(formattedMessage);
            window.webkit.messageHandlers.__turf__.postMessage(jsonMessage);
            console.log('Sent message to native app:', jsonMessage);
        } else {
            console.error('Native communication not available');
        }
    }

    // User can register handlers for events from the native app
    function onWindowGeometryChanged(handler_function) {
        registry['window_geometry'] = handler_function;
    }

    function onFileSelected(handler_function) {
        registry['file_selected'] = handler_function;
    }

    function onMessage(message_type, handler_function) {
        registry[message_type] = handler_function;
    }

    function nativeFileSelect() {
        send({
            type: 'show_file_dialog',
            data: null,
        });
    }

    // Internal function to handle messages from native
    function handleNativeMessage(msg) {
        console.log('Native message received:', msg);
        
        // Call registered handlers based on message type
        if (msg.type && registry[msg.type]) {
            registry[msg.type](msg.data);
        } else if (registry['native_message']) {
            // Fallback to generic handler
            registry['native_message'](msg);
        }
    }

    // Topic events are separate from the existing native message registry.
    const topics = new Map();
    const retained = new Map();
    function callTopic(handler, packet, replayed) {
        try {
            // Each listener receives its own JSON value, so mutation cannot affect peers.
            const result = handler(JSON.parse(packet.json), Object.freeze({
                topic: packet.topic, seq: packet.seq, ts: packet.ts, replayed
            }));
            Promise.resolve(result).catch(error => console.error('Turf topic handler rejected', error));
            return true;
        } catch (error) {
            console.error('Turf topic handler failed', error);
            return false;
        }
    }
    function on(topic, handler) {
        if (typeof topic !== 'string' || !topic.length || typeof handler !== 'function')
            throw new TypeError('turf.on requires a nonempty topic and a function');
        let handlers = topics.get(topic);
        if (!handlers) topics.set(topic, handlers = new Set());
        const subscription = {handler};
        handlers.add(subscription);
        for (const packet of [...retained.values()].sort((a, b) => a.seq - b.seq))
            if (topic === '*' || topic === packet.topic) callTopic(handler, packet, true);
        return () => {
            handlers.delete(subscription);
            if (!handlers.size && topics.get(topic) === handlers) topics.delete(topic);
        };
    }
    function emitPacket(packet, replayed = false) {
        if (packet.clear) { retained.delete(packet.topic); return {handlers: 0, failures: 0}; }
        if (packet.retain) {
            const previous = retained.get(packet.topic);
            if (previous && previous.seq >= packet.seq) return {handlers: 0, failures: 0};
            retained.set(packet.topic, packet);
        }
        const listeners = [...(topics.get(packet.topic) || []), ...(topics.get('*') || [])];
        let failures = 0;
        for (const {handler} of listeners) if (!callTopic(handler, packet, replayed)) failures++;
        return {handlers: listeners.length, failures};
    }

    // Export functions for use in other files
    window.turf = {
        on: on,
        _emit: emitPacket,
        _clearRetained: () => retained.clear(),
        send: send,
        onWindowGeometryChanged: onWindowGeometryChanged,
        onFileSelected: onFileSelected,
        onMessage: onMessage,
        nativeFileSelect: nativeFileSelect,
        _handleNativeMessage: handleNativeMessage
    };

    window.dispatchEvent(new Event('turf-ready'));

    const logoMode = typeof startupLogo === 'undefined' ? 'off' : startupLogo;

    // Add the CSS and signature after DOM is ready
    function addTurfSignature() {
        if (logoMode === 'off') return;
        // Add the CSS keyframes for the shimmer effect
        const style = document.createElement('style');
        style.textContent = `
#turf-signature {
  position: fixed;
  bottom: 8px;
  right: 8px;
  font-size: 20px;
  z-index: 9999;
  transform-origin: center;
  color: #666;
}

#turf-signature.animate {
  background-image:
    linear-gradient(90deg, transparent 20%, rgba(255,255,255,0.8) 50%, transparent 80%),
    linear-gradient(90deg, #ff0000, #ff8000, #ffff00, #00ff00, #0080ff, #8000ff);
  background-size: 200% 100%, 100% 100%;
  animation: rainbowShimmer 1.5s ease-in-out forwards;
}

#turf-signature.disappear {
  animation: turfDisappear 0.4s ease-out 0.2s forwards;
}

@keyframes turfDisappear {
  to { opacity: 0; }
}

@keyframes rainbowShimmer {
  0% {
    background-position: -150% 0, 0 0;
    transform: scale(1);
    color: transparent;
    -webkit-background-clip: text;
    background-clip: text;
  }
  50% {
    transform: scale(1.15);
    color: transparent;
    -webkit-background-clip: text;
    background-clip: text;
  }
  100% {
    background-position: 250% 0, 0 0;
    transform: scale(1);
    color: transparent;
    -webkit-background-clip: text;
    background-clip: text;
  }
}`;
        document.head.appendChild(style);

        document.body.insertAdjacentHTML('beforeend',
          '<div id="turf-signature" class="animate">𝓽𝓾𝓻𝓯</div>');

        const signatureElement = document.getElementById('turf-signature');
        if (signatureElement) {
          signatureElement.addEventListener('animationend', () => {
            signatureElement.classList.remove('animate');
            if (logoMode === 'in_out') {
              signatureElement.classList.add('disappear');
              signatureElement.addEventListener('animationend', () => {
                signatureElement.remove();
                style.remove();
              }, { once: true });
            }
          }, { once: true });
        }

    }

    function onReady() {
        addTurfSignature();
        window.turf.send({
            type: 'turf_ready',
            data: 'At your service!'
        });
    }

    // Wait for DOM to be ready before adding signature
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', onReady, { once: true });
    } else {
        // DOM is already ready
        onReady();
    }

    // Listen for messages from the native application (legacy event-based approach)
    window.addEventListener('__turf__', function(event) {
        const message = event.data.message;
        // bubble up the message to a registered handler from the 
        // user's code if the user has registered one.
        if (message.type === 'window_geometry') {
            if (registry['window_geometry']) {
                registry['window_geometry'](message.data);
            }
        } else if (message.type === 'file_selected') {
            if (registry['file_selected']) {
                registry['file_selected'](message.data);
            }
        } else {
            if (registry['native_message']) {
                registry['native_message'](message.data);
            }
        }
    });

})();
