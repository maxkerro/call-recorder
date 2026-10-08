'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const info = require('../src/lib/appinfo');

test('About box facts are complete and the Mac and Windows versions agree', () => {
  assert.ok(info.summary.length > 40 && info.author && info.releaseDate);
  const root = path.join(__dirname, '..', '..');
  assert.match(fs.readFileSync(path.join(root, 'Info.plist'), 'utf8'), new RegExp(`ShortVersionString</key><string>${info.version}</string>`));
  assert.match(fs.readFileSync(path.join(root, 'Sources', 'CallRecorder', 'AppInfo.swift'), 'utf8'), new RegExp(`version = "${info.version}"`));
  assert.match(fs.readFileSync(path.join(root, 'Info.plist'), 'utf8'), new RegExp(`CFBundleVersion</key><string>${info.build}</string>`));
  assert.match(fs.readFileSync(path.join(root, 'Sources', 'CallRecorder', 'AppInfo.swift'), 'utf8'), new RegExp(`build = "${info.build}"`));
  assert.match(fs.readFileSync(path.join(root, 'Sources', 'CallRecorder', 'AppInfo.swift'), 'utf8'), new RegExp(`releaseDate = "${info.releaseDate}"`));
});
