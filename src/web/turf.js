// This script is injected into the webview when the window is created.
// It is injected after the local file is loaded.
// It is used to send and receive messages from the native application.

// Listen for messages from the native application.
window.addEventListener('__turf__', function(event) {
        const message = event.data.message;
        // bubble up  the message to a registered handler from the 
        // user's code if the user has registered one.
        if (message.type === 'window_geometry') {
            if (registry['window_geometry']) {
                registry['window_geometry'](message.data);
            }
            // You can add UI updates here if needed
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

// registry dictionary to store the handlers for the messages
const registry = {};


// User can register handlers for events from the native app

function onWindowGeometryChanged(handler_function) {
    registry['window_geometry'] = handler_function;
}

function onFileSelected(handler_function) {
    registry['file_select'] = handler_function;
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

// Send a message to the native application.
function send(message) {
    if (window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.__turf__) {
        let msg_data = '';
        if (typeof message.data === 'string') {
            msg_data = message.data;
        } else {
            msg_data = JSON.stringify(message.data);
        }
        // Format message to match Zig's expected structure
        const formattedMessage = JSON.stringify({
            type: message.type,
            message: msg_data,
        });
        window.webkit.messageHandlers.__turf__.postMessage(formattedMessage);
        console.log('Sent message to native app:', formattedMessage);
    } else {
        console.error('Native communication not available');
    }
}


// Export functions for use in other files
window.turf = {
    send,
    onWindowGeometryChanged,
    onFileSelected,
    onMessage,
    nativeFileSelect,
};

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
