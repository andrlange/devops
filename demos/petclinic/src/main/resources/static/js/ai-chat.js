/**
 * AiChat — SockJS/STOMP client for the Petclinic AI assistant.
 *
 * Depends on (loaded via CDN before this script):
 *   - sockjs-client@1  (window.SockJS)
 *   - @stomp/stompjs@7 (window.StompJs)
 */
const AiChat = {

    stompClient: null,
    sessionId: null,
    connected: false,

    /** The current AI response <div> being streamed into */
    currentResponseDiv: null,
    /** Accumulated raw text for the current AI turn */
    currentResponseText: '',
    /** The chat container element that owns the current response */
    currentContainer: null,

    // ------------------------------------------------------------------ //
    //  Connection
    // ------------------------------------------------------------------ //

    /**
     * Connect to the WebSocket endpoint.
     * @param {string|null} sessionId  - Reuse an existing session or pass null for a new one.
     * @param {Function}    onConnected - Called when the STOMP handshake succeeds.
     * @param {Function}    onError     - Called with an error message string on failure.
     */
    connect(sessionId, onConnected, onError) {
        this.sessionId = sessionId || this.generateSessionId();

        const socket = new SockJS('/ws');
        this.stompClient = new StompJs.Client({
            webSocketFactory: () => socket,
            reconnectDelay: 0,
            onConnect: () => {
                this.connected = true;
                this.subscribe();
                if (onConnected) onConnected();
            },
            onStompError: (frame) => {
                this.connected = false;
                if (onError) onError(frame.headers['message'] || 'STOMP error');
            },
            onDisconnect: () => {
                this.connected = false;
            }
        });

        this.stompClient.activate();
    },

    /** Gracefully disconnect the STOMP client. */
    disconnect() {
        if (this.stompClient) {
            this.stompClient.deactivate();
            this.connected = false;
        }
    },

    // ------------------------------------------------------------------ //
    //  Subscription
    // ------------------------------------------------------------------ //

    /** Subscribe to the per-session topic after connecting. */
    subscribe() {
        this.stompClient.subscribe('/topic/chat.' + this.sessionId, (message) => {
            const response = JSON.parse(message.body);
            switch (response.type) {
                case 'token':   this.renderToken(response.content);   break;
                case 'done':    this.renderComplete();                 break;
                case 'error':   this.renderError(response.content);   break;
                case 'sources': this.renderSources(response.content); break;
            }
        });
    },

    // ------------------------------------------------------------------ //
    //  Sending
    // ------------------------------------------------------------------ //

    /**
     * Send a user message and prepare the response UI.
     * @param {string}      content       - The user's message text.
     * @param {number|null} petId         - Optional pet context.
     * @param {Element}     chatContainer - The scrollable messages container.
     */
    sendMessage(content, petId, chatContainer) {
        if (!this.connected || !content.trim()) return;

        this.currentContainer = chatContainer;

        // Render the user's bubble immediately
        this.appendUserMessage(content, chatContainer);

        // Create the (initially empty) AI response container
        this.prepareResponseContainer(chatContainer);

        // Publish via STOMP
        this.stompClient.publish({
            destination: '/app/chat.send',
            body: JSON.stringify({
                content: content,
                sessionId: this.sessionId,
                petId: petId || null
            })
        });
    },

    // ------------------------------------------------------------------ //
    //  Render helpers
    // ------------------------------------------------------------------ //

    /**
     * Append a right-aligned user bubble to the container.
     */
    appendUserMessage(content, container) {
        const wrapper = document.createElement('div');
        wrapper.className = 'ai-message ai-message-user';

        const bubble = document.createElement('div');
        bubble.className = 'ai-message-bubble';
        bubble.textContent = content;

        wrapper.appendChild(bubble);
        container.appendChild(wrapper);
        this.scrollToBottom(container);
    },

    /**
     * Create the left-aligned AI message shell that tokens will stream into.
     */
    prepareResponseContainer(container) {
        this.currentResponseText = '';

        const wrapper = document.createElement('div');
        wrapper.className = 'ai-message ai-message-ai';

        // Paw avatar
        const avatar = document.createElement('div');
        avatar.className = 'ai-avatar';
        avatar.textContent = '🐾';

        // Content area
        const bubble = document.createElement('div');
        bubble.className = 'ai-message-bubble';

        // Typing indicator shown while waiting for the first token
        const typing = document.createElement('span');
        typing.className = 'ai-typing-indicator';
        typing.innerHTML = '<span></span><span></span><span></span>';
        bubble.appendChild(typing);

        // The actual text div (hidden until first token arrives)
        const textDiv = document.createElement('div');
        textDiv.className = 'ai-response-text';
        textDiv.style.display = 'none';
        bubble.appendChild(textDiv);

        wrapper.appendChild(avatar);
        wrapper.appendChild(bubble);
        container.appendChild(wrapper);

        this.currentResponseDiv = textDiv;
        this.scrollToBottom(container);
    },

    /**
     * Append a streamed token to the current AI response.
     */
    renderToken(token) {
        if (!this.currentResponseDiv) return;

        this.currentResponseText += token;

        // Hide typing indicator on first token
        const typingEl = this.currentResponseDiv.closest('.ai-message-bubble').querySelector('.ai-typing-indicator');
        if (typingEl) typingEl.style.display = 'none';

        this.currentResponseDiv.style.display = '';
        this.currentResponseDiv.innerHTML = this._markdownToHtml(this.currentResponseText);

        if (this.currentContainer) this.scrollToBottom(this.currentContainer);
    },

    /**
     * Finalise the current AI response (streaming complete).
     */
    renderComplete() {
        if (!this.currentResponseDiv) return;

        // Remove typing indicator if it's still there (e.g. empty response)
        const bubble = this.currentResponseDiv.closest('.ai-message-bubble');
        if (bubble) {
            const typingEl = bubble.querySelector('.ai-typing-indicator');
            if (typingEl) typingEl.remove();
        }

        // Render the final markdown pass
        if (this.currentResponseText) {
            this.currentResponseDiv.innerHTML = this._markdownToHtml(this.currentResponseText);
            this.currentResponseDiv.style.display = '';
        } else {
            // Empty response fallback
            this.currentResponseDiv.textContent = '(No response)';
            this.currentResponseDiv.style.display = '';
        }

        if (this.currentContainer) this.scrollToBottom(this.currentContainer);

        // Reset streaming state
        this.currentResponseDiv = null;
        this.currentResponseText = '';
    },

    /**
     * Display an error bubble in place of the AI response.
     */
    renderError(message) {
        if (this.currentResponseDiv) {
            const bubble = this.currentResponseDiv.closest('.ai-message-bubble');
            if (bubble) {
                const typingEl = bubble.querySelector('.ai-typing-indicator');
                if (typingEl) typingEl.remove();
            }
            this.currentResponseDiv.innerHTML =
                '<span class="ai-error"><i class="bi bi-exclamation-triangle-fill me-1"></i>' +
                this._escapeHtml(message) + '</span>';
            this.currentResponseDiv.style.display = '';
        }

        if (this.currentContainer) this.scrollToBottom(this.currentContainer);

        this.currentResponseDiv = null;
        this.currentResponseText = '';
    },

    /**
     * Render source-attribution line below the current AI bubble.
     * @param {string} sourcesJson - JSON array of {title, category} objects.
     */
    renderSources(sourcesJson) {
        // Sources arrive before tokens; attach them after the next renderComplete.
        // We store them on the pending bubble element and flush in renderComplete.
        try {
            const sources = JSON.parse(sourcesJson);
            if (!sources || sources.length === 0) return;

            // We may not have a currentResponseDiv yet if sources arrive first.
            // Store on `this` and flush once the bubble exists.
            this._pendingSources = sources;
            this._flushPendingSources();
        } catch (e) {
            // Ignore malformed sources payload
        }
    },

    /** Attach pending sources to the current bubble if it already exists. */
    _flushPendingSources() {
        if (!this._pendingSources || !this._pendingSources.length) return;
        if (!this.currentResponseDiv) return;

        const sources = this._pendingSources;
        this._pendingSources = null;

        const bubble = this.currentResponseDiv.closest('.ai-message-bubble');
        if (!bubble) return;

        // Avoid duplicates
        if (bubble.querySelector('.ai-sources')) return;

        const sourcesEl = document.createElement('div');
        sourcesEl.className = 'ai-sources';

        const titles = sources.map(s => {
            const span = document.createElement('span');
            span.className = 'ai-source-item';
            span.textContent = s.title;
            if (s.category) span.title = s.category;
            return span.outerHTML;
        }).join(', ');

        sourcesEl.innerHTML = '<i class="bi bi-journal-text me-1"></i><small>Based on: ' + titles + '</small>';
        bubble.appendChild(sourcesEl);
    },

    /**
     * Ensure the container is scrolled to its latest message.
     */
    scrollToBottom(container) {
        if (!container) return;
        container.scrollTop = container.scrollHeight;
    },

    // ------------------------------------------------------------------ //
    //  History / Sessions
    // ------------------------------------------------------------------ //

    /**
     * Load persisted chat history for a pet and render it into a container.
     * @param {number}  petId     - The pet's database ID.
     * @param {Element} container - The messages container element.
     */
    loadHistory(petId, container) {
        fetch('/ai/chat/history/' + petId)
            .then(r => r.json())
            .then(messages => {
                if (!messages || messages.length === 0) return;

                messages.forEach(msg => {
                    if (msg.role === 'user') {
                        this.appendUserMessage(msg.content, container);
                    } else if (msg.role === 'assistant') {
                        const wrapper = document.createElement('div');
                        wrapper.className = 'ai-message ai-message-ai';

                        const avatar = document.createElement('div');
                        avatar.className = 'ai-avatar';
                        avatar.textContent = '🐾';

                        const bubble = document.createElement('div');
                        bubble.className = 'ai-message-bubble';

                        const textDiv = document.createElement('div');
                        textDiv.className = 'ai-response-text';
                        textDiv.innerHTML = this._markdownToHtml(msg.content);
                        bubble.appendChild(textDiv);

                        if (msg.knowledgeRefs) {
                            const srcEl = document.createElement('div');
                            srcEl.className = 'ai-sources';
                            srcEl.innerHTML = '<i class="bi bi-journal-text me-1"></i><small>Based on: ' +
                                this._escapeHtml(msg.knowledgeRefs) + '</small>';
                            bubble.appendChild(srcEl);
                        }

                        wrapper.appendChild(avatar);
                        wrapper.appendChild(bubble);
                        container.appendChild(wrapper);
                    }
                });

                this.scrollToBottom(container);
            })
            .catch(err => console.error('Failed to load chat history:', err));
    },

    /**
     * Load chat sessions for a pet and call back with the list.
     * @param {number}   petId    - The pet's database ID.
     * @param {Function} callback - Called with the array of session summaries.
     */
    loadSessions(petId, callback) {
        fetch('/ai/chat/sessions/' + petId)
            .then(r => r.json())
            .then(sessions => callback(sessions))
            .catch(err => {
                console.error('Failed to load chat sessions:', err);
                callback([]);
            });
    },

    // ------------------------------------------------------------------ //
    //  Utilities
    // ------------------------------------------------------------------ //

    /** Generate a random UUID for a new chat session. */
    generateSessionId() {
        return crypto.randomUUID();
    },

    /**
     * Minimal Markdown → HTML converter.
     * Handles: **bold**, *italic*, `inline code`, ``` code blocks,
     *           unordered bullet lists, and line breaks.
     */
    _markdownToHtml(text) {
        if (!text) return '';

        let html = text;

        // Fenced code blocks (``` ... ```)
        html = html.replace(/```[\w]*\n?([\s\S]*?)```/g, (_, code) =>
            '<pre><code>' + this._escapeHtml(code.trim()) + '</code></pre>'
        );

        // Inline code
        html = html.replace(/`([^`]+)`/g, (_, code) =>
            '<code>' + this._escapeHtml(code) + '</code>'
        );

        // Bold (**text**)
        html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');

        // Italic (*text*)
        html = html.replace(/\*([^*]+)\*/g, '<em>$1</em>');

        // Unordered bullet lists (lines starting with - or *)
        html = html.replace(/^[ \t]*[-*][ \t]+(.+)$/gm, '<li>$1</li>');
        // Wrap consecutive <li> in <ul>
        html = html.replace(/(<li>[\s\S]*?<\/li>)(\n<li>[\s\S]*?<\/li>)*/g, match =>
            '<ul>' + match + '</ul>'
        );

        // Line breaks — two spaces + newline or bare newline
        html = html.replace(/  \n/g, '<br>');
        html = html.replace(/\n/g, '<br>');

        return html;
    },

    /** HTML-escape a plain string to prevent XSS. */
    _escapeHtml(str) {
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    },

    /** Internal storage for sources arriving before the response bubble exists. */
    _pendingSources: null
};
