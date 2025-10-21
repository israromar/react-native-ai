"use strict";

var _reactNative = require("react-native");
var _structuredClone = _interopRequireDefault(require("@ungap/structured-clone"));
var _PolyfillFunctions = require("react-native/Libraries/Utilities/PolyfillFunctions");
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
function _getRequireWildcardCache(e) { if ("function" != typeof WeakMap) return null; var r = new WeakMap(), t = new WeakMap(); return (_getRequireWildcardCache = function (e) { return e ? t : r; })(e); }
function _interopRequireWildcard(e, r) { if (!r && e && e.__esModule) return e; if (null === e || "object" != typeof e && "function" != typeof e) return { default: e }; var t = _getRequireWildcardCache(r); if (t && t.has(e)) return t.get(e); var n = { __proto__: null }, a = Object.defineProperty && Object.getOwnPropertyDescriptor; for (var u in e) if ("default" !== u && {}.hasOwnProperty.call(e, u)) { var i = a ? Object.getOwnPropertyDescriptor(e, u) : null; i && (i.get || i.set) ? Object.defineProperty(n, u, i) : n[u] = e[u]; } return n.default = e, t && t.set(e, n), n; } // @ts-nocheck
if (_reactNative.Platform.OS !== 'web') {
  const setupPolyfills = async () => {
    const {
      TextDecoderStream,
      TextEncoderStream
    } = await Promise.resolve().then(() => _interopRequireWildcard(require('@stardazed/streams-text-encoding')));
    const webStreamPolyfills = require('web-streams-polyfill/ponyfill/es6');
    if (!('structuredClone' in global)) {
      (0, _PolyfillFunctions.polyfillGlobal)('structuredClone', () => _structuredClone.default);
    }
    (0, _PolyfillFunctions.polyfillGlobal)('ReadableStream', () => webStreamPolyfills.ReadableStream);
    (0, _PolyfillFunctions.polyfillGlobal)('TransformStream', () => webStreamPolyfills.TransformStream);
    (0, _PolyfillFunctions.polyfillGlobal)('WritableStream', () => webStreamPolyfills.WritableStream);
    (0, _PolyfillFunctions.polyfillGlobal)('TextDecoderStream', () => TextDecoderStream);
    (0, _PolyfillFunctions.polyfillGlobal)('TextEncoderStream', () => TextEncoderStream);
  };
  setupPolyfills();
}
//# sourceMappingURL=polyfills.js.map