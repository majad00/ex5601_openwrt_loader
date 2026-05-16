'use strict';
'require view';
'require rpc';
'require ui';

var callStartStock = rpc.declare({
	object: 'matrix',
	method: 'start',
	expect: { }
});

var callStartUbootmod = rpc.declare({
	object: 'matrix',
	method: 'start_ubootmod',
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

		var stockButton = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'style': 'margin-right:12px'
		}, [ _('Flash OpenWrt-Stock Layout') ]);

		var ubootmodButton = E('button', {
			'class': 'cbi-button cbi-button-negative'
		}, [ _('Flash OpenWrt-Uboot Layout') ]);

		function startFlash(button, normalText, rpcCall, confirmText) {
			if (!window.confirm(confirmText))
				return;

			button.disabled = true;
			button.textContent = _('Starting...');

			rpcCall().then(function(res) {
				if (!res || res.ok !== true) {
					ui.addNotification(null,
						E('p', {}, [ res && res.message ? res.message : _('Failed to start flash') ]),
						'danger'
					);
				}
				else {
					ui.addNotification(null,
						E('p', {}, [ res.message || _('Flash started') ]),
						'info'
					);
				}

				button.textContent = normalText;
				button.disabled = false;
				updateLog();
			}).catch(function(err) {
				ui.addNotification(null,
					E('p', {}, [ _('RPC error: ') + err ]),
					'danger'
				);

				button.textContent = normalText;
				button.disabled = false;
				updateLog();
			});
		}

		stockButton.addEventListener('click', function(ev) {
			ev.preventDefault();

			startFlash(
				stockButton,
				_('Flash OpenWrt-Stock Layout'),
				callStartStock,
				_('Flash OpenWrt stock layout and reboot? Do not power off the router.')
			);
		});

		ubootmodButton.addEventListener('click', function(ev) {
			ev.preventDefault();

			startFlash(
				ubootmodButton,
				_('Flash OpenWrt-Uboot Layout'),
				callStartUbootmod,
				_('This will reboot for OpenWrt U-Boot flashing in inintramfs, and can take about two min. Continue?')
			);
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
				_('Do not power off the router while flashing or staging an installer.')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Stock layout installation') ]),
				E('p', {}, [
					_('Installs OpenWrt using the original Zyxel dual-bank stock layout.')
				]),
				E('p', {}, [ stockButton ])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('U-Boot layout installer') ]),
				E('p', {}, [
					_('Stages a temporary initramfs installer for the OpenWrt U-Boot layout installation.')
				]),
				E('p', {}, [ ubootmodButton ])
			]),

			E('h3', {}, [ _('Status') ]),
			logBox
		]);
	}
});
