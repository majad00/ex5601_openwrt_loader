'use strict';

const fs = require('fs');

const DIR = '/tmp/matrix-flash';
const REQ = DIR + '/request';
const RUNNING = DIR + '/running';
const LOG = DIR + '/status.log';

function ensure_dir() {
	if (!fs.stat(DIR))
		fs.mkdir(DIR, 493);
}

function read_log() {
	let data = fs.readfile(LOG);

	if (data == null)
		return 'Matrix flash runner is ready.\n';

	return data;
}

return {
	matrix: {
		start: {
			call: function(req) {
				ensure_dir();

				if (fs.stat(RUNNING)) {
					return {
						ok: false,
						message: 'Flash already running'
					};
				}

				fs.writefile(REQ, 'start\n');

				return {
					ok: true,
					message: 'Flash request queued'
				};
			}
		},

		status: {
			call: function(req) {
				ensure_dir();

				return {
					ok: true,
					running: fs.stat(RUNNING) ? true : false,
					log: read_log()
				};
			}
		}
	}
};

