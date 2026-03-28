import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';

/// Call state.
enum CallState { idle, ringing, connecting, connected, ended }

/// Call type.
enum CallType { audio, video }

/// Manages WebRTC audio/video calls using the relay for signaling.
class CallService extends ChangeNotifier {
  final RelayService _signaling = RelayService();
  final RustCoreService _rustCore = RustCoreService();
  String? _myPublicKey;

  // WebRTC
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // State
  CallState _state = CallState.idle;
  CallType _callType = CallType.audio;
  String? _remoteContactKey;
  String? _remoteContactName;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isSpeakerOn = false;
  bool _isIncomingCall = false;
  String? _pendingOffer;

  // Getters
  CallState get state => _state;
  CallType get callType => _callType;
  String? get remoteContactKey => _remoteContactKey;
  String? get remoteContactName => _remoteContactName;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isIncomingCall => _isIncomingCall;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  /// Callback when an incoming call arrives.
  void Function(String contactKey, String contactName, CallType type)? onIncomingCall;

  // STUN servers for NAT traversal (free, public)
  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'},
  ];

  void setMyPublicKey(String key) {
    _myPublicKey = key;
    _signaling.onMessageReceived = _handleSignaling;
  }

  /// Connect signaling channel for a contact.
  void connectSignaling(String contactKey) {
    if (_myPublicKey == null) return;
    
    // Connect to relay
    _signaling.connect(
      'call:$_myPublicKey',
      'call:$contactKey',
    );

    // Initialize secure session in Rust Core for signaling privacy
    final sharedSecret = CryptoService.deriveSharedKey(_myPublicKey!, contactKey);
    _rustCore.initiateSession(contactKey, base64Encode(utf8.encode(sharedSecret)));
  }

  /// Start an outgoing call.
...
