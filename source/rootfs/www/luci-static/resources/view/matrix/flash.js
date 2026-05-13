'use strict';
'require view';
'require rpc';
'require ui';

var callStart = rpc.declare({
	object: 'matrix',
	method: 'start',
	expect: { }
});

var callStatus = rpc.declare({
	object: 'matrix',
	method: 'status',
	expect: { }
});

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(data) {
		var logBox = E('pre', {
			'id': 'matrix-log',
			'style': 'background:#111;color:#eee;padding:12px;min-height:320px;white-space:pre-wrap;overflow:auto'
		}, [ data.log || 'No status yet.' ]);

		var button = E('button', {
			'class': 'cbi-button cbi-button-apply'
		}, [ _('Flash OpenWrt') ]);

		button.addEventListener('click', function(ev) {
			ev.preventDefault();

			if (!window.confirm(_('Flash OpenWrt to the inactive slot and reboot? Do not power off the router.')))
				return;

			button.disabled = true;
			button.textContent = _('Starting...');

			callStart().then(function(res) {
				if (!res || res.ok !== true)
					ui.addNotification(null, E('p', {}, [ res && res.message ? res.message : _('Failed to start flash') ]), 'danger');
				else
					ui.addNotification(null, E('p', {}, [ res.message || _('Flash started') ]), 'info');

				button.textContent = _('Flash OpenWrt');
				button.disabled = false;
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, [ _('RPC error: ') + err ]), 'danger');
				button.textContent = _('Flash OpenWrt');
				button.disabled = false;
			});
		});

		function updateLog() {
			callStatus().then(function(res) {
				if (res && res.log)
					logBox.textContent = res.log;
			}).catch(function() {
				logBox.textContent = 'Unable to read Matrix status.';
			});
		}

		window.setInterval(updateLog, 1500);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('Matrix OpenWrt Installer') ]),

			E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, [ _('Warning: ') ]),
				_('This will flash OpenWrt to the inactive firmware slot and reboot the router. Do not power off the device.')
			]),

			E('p', {}, [ button ]),

			E('h3', {}, [ _('Status') ]),
			logBox
		]);
	}
});
