'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require dom';

// rpcd file-exec bindings. Each maps to workbuddy-ctl, so the page never needs
// shell access of its own.
var callStatus     = rpc.declare({ object: 'file', method: 'exec', params: [ 'command', 'params' ], filter: function (r) { return r; } });

function ctl(args) {
	return callStatus('/usr/bin/workbuddy-ctl', args || [ 'status' ]).then(function (r) {
		var out = (r && r.stdout) ? r.stdout.trim() : '';
		if (!out) return null;
		try { return JSON.parse(out); } catch (e) { return { raw: out }; }
	});
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('workbuddy'),
			ctl([ 'status' ]),
		]);
	},

	// Renders the token panel plus the live login flow.
	renderTokenPanel: function (status) {
		var self = this;
		var token = uci.get('workbuddy', 'main', 'access_token') || '';
		var masked = token ? (token.substring(0, 12) + '...' + token.substring(token.length - 6)) : '';

		var box = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Authorization')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Current token')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', { 'id': 'wb-token-state' },
						token ? E('code', {}, masked) : E('em', {}, _('not configured'))),
				]),
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Token')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'id': 'wb-token-input', 'type': 'text', 'class': 'cbi-input-text',
						'style': 'width:100%',
						'placeholder': _('paste an access token here'),
					}),
					E('div', { 'class': 'cbi-value-description' },
						_('Leave empty to keep the stored token. Obtain one with the button below.')),
				]),
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Actions')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleLogin'),
					}, _('Log in to WorkBuddy')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-negative',
						'click': ui.createHandlerFn(self, 'handleClearToken'),
					}, _('Clear token')),
				]),
			]),
			E('div', { 'id': 'wb-login-area' }),
		]);

		return box;
	},

	handleLogin: function (ev) {
		var area = document.getElementById('wb-login-area');
		area.innerHTML = '';
		area.appendChild(E('p', {}, _('Requesting a login link...')));

		return ctl([ 'login-start' ]).then(function (r) {
			area.innerHTML = '';

			if (!r || !r.authUrl) {
				area.appendChild(E('p', { 'class': 'alert-message error' },
					_('Could not start login: %s').format((r && (r.raw || r.error)) || '?')));
				return;
			}

			var win = window.open(r.authUrl, '_blank');

			area.appendChild(E('p', {}, _('Complete the login in the opened tab, then wait here.')));
			area.appendChild(E('p', {}, [
				E('a', { 'href': r.authUrl, 'target': '_blank' }, r.authUrl),
			]));
			area.appendChild(E('p', { 'id': 'wb-poll-status' }, _('Waiting for authorization...')));

			if (!win)
				area.appendChild(E('p', { 'class': 'alert-message warning' },
					_('The popup was blocked. Open the link above manually.')));

			// Poll every 3s; the upstream state is valid for 5 minutes.
			var tries = 0;
			var timer = setInterval(function () {
				tries++;
				if (tries > 100) {
					clearInterval(timer);
					document.getElementById('wb-poll-status').textContent = _('Timed out.');
					return;
				}
				ctl([ 'login-poll', r.state ]).then(function (p) {
					var el = document.getElementById('wb-poll-status');
					if (!el) { clearInterval(timer); return; }

					if (!p) return;

					if (p.status === 'ok' || p.accessToken) {
						clearInterval(timer);
						el.textContent = _('Authorized. Reloading...');
						window.location.reload();
					} else if (p.status === 'failed') {
						clearInterval(timer);
						el.textContent = _('Login failed: %s').format(p.message || '?');
					}
				});
			}, 3000);
		});
	},

	handleClearToken: function () {
		return ctl([ 'clear-token' ]).then(function () {
			window.location.reload();
		});
	},

	render: function (data) {
		var self = this;
		var status = data[1] || {};

		var m, s, o;

		m = new form.Map('workbuddy', _('WorkBuddy Relay'),
			_('Shares the free WorkBuddy models with every device on your LAN through an OpenAI-compatible endpoint.'));

		s = m.section(form.NamedSection, 'main', 'workbuddy', _('Service'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o.default = '0';

		o = s.option(form.Value, 'listen_port', _('Listen port'));
		o.datatype = 'port';
		o.default = '8789';
		o.rmempty = false;

		o = s.option(form.ListValue, 'listen_host', _('Listen address'));
		o.value('0.0.0.0', _('All interfaces (LAN accessible)'));
		o.value('127.0.0.1', _('Localhost only'));
		o.default = '0.0.0.0';

		o = s.option(form.Flag, 'free_only', _('Free models only'));
		o.default = '1';
		o.description = _('Expose only the models that are currently free.') + ' ' +
			_('Turn this off to also relay paid models.');

		o = s.option(form.Flag, 'debug', _('Verbose logging'));
		o.default = '0';

		var view = m.render().then(function (node) {
			var panel = self.renderTokenPanel(status);
			var anchor = node.querySelector('.cbi-section');
			if (anchor && anchor.parentNode)
				anchor.parentNode.insertBefore(panel, anchor.nextSibling);
			else
				node.appendChild(panel);
			return node;
		});

		return view;
	},

	// Shown above the page: where LAN clients should point.
	renderEndpointHint: function (status) {
		var host = window.location.hostname;
		var port = (status && status.port) || 8789;
		var base = 'http://%s:%d/v1'.format(host, port);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Endpoint for other devices')),
			E('p', {}, _('Point any OpenAI-compatible client at:')),
			E('pre', {}, base),
			E('p', { 'class': 'cbi-value-description' },
				_('Use the model ids listed below. The API key may be left empty unless a share token is configured.')),
			E('p', {}, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () {
						return ctl([ 'models' ]).then(function (r) {
							ui.showModal(_('Available models'), [
								E('pre', {}, (r && (r.raw || JSON.stringify(r, null, 2))) || _('none')),
								E('div', { 'class': 'right' }, [
									E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')),
								]),
							]);
						});
					}),
				}, _('Show available models')),
			]),
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
});
