'use strict';

const fs = require('fs');

const STOCK_DIR = '/tmp/matrix-flash';
const STOCK_REQ = STOCK_DIR + '/request';
const STOCK_RUNNING = STOCK_DIR + '/running';
const STOCK_LOG = STOCK_DIR + '/status.log';

const UBOOT_DIR = '/tmp/matrix-ubootmod';
const UBOOT_REQ = UBOOT_DIR + '/request';
const UBOOT_RUNNING = UBOOT_DIR + '/running';
const UBOOT_LOG = UBOOT_DIR + '/status.log';

function ensure_dir(dir) {
	if (!fs.stat(dir))
		fs.mkdir(dir, 493);
}

function ensure_all_dirs() {
	ensure_dir(STOCK_DIR);
	ensure_dir(UBOOT_DIR);
}

function is_running() {
	return fs.stat(STOCK_RUNNING) || fs.stat(UBOOT_RUNNING);
}

function read_log(title, path) {
	let data = fs.readfile(path);

	if (data == null)
		data = 'No log yet.\n';

	return '===== ' + title + ' =====\n' + data + '\n';
}

return {
	matrix: {
		start: {
			call: function(req) {
				ensure_all_dirs();

				if (is_running()) {
					return {
						ok: false,
						message: 'Another Matrix operation is already running'
					};
				}

				fs.writefile(STOCK_REQ, 'start\n');

				return {
					ok: true,
					message: 'Stock-layout flash request queued'
				};
			}
		},

		start_ubootmod: {
			call: function(req) {
				ensure_all_dirs();

				if (is_running()) {
					return {
						ok: false,
						message: 'Another Matrix operation is already running'
					};
				}

				fs.writefile(UBOOT_REQ, 'start\n');

				return {
					ok: true,
					message: 'U-Boot layout initramfs staging request queued'
				};
			}
		},

		status: {
			call: function(req) {
				ensure_all_dirs();

				return {
					ok: true,
					running_stock: fs.stat(STOCK_RUNNING) ? true : false,
					running_ubootmod: fs.stat(UBOOT_RUNNING) ? true : false,
					log: read_log('Stock Layout', STOCK_LOG) + '\n' + read_log('U-Boot Layout', UBOOT_LOG)
				};
			}
		}
	}
};

