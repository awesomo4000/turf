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

    // Export functions for use in other files
    window.turf = {
        send: send,
        onWindowGeometryChanged: onWindowGeometryChanged,
        onFileSelected: onFileSelected,
        onMessage: onMessage,
        nativeFileSelect: nativeFileSelect,
        _handleNativeMessage: handleNativeMessage
    };

    // Add the CSS and signature after DOM is ready
    function addTurfSignature() {
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
          }, { once: true });
        }

        window.turf.send({
            type: 'turf_ready',
            data: 'At your service!'
        });
    }

    // Wait for DOM to be ready before adding signature
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', addTurfSignature);
    } else {
        // DOM is already ready
        addTurfSignature();
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