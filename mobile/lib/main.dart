import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

const tokenServerUrl = 'http://10.47.157.118:8787';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LiveKitClient.initialize();

  runApp(const TeloApp());
}

class TeloApp extends StatelessWidget {
  const TeloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const TeloHome(),
    );
  }
}

class TeloHome extends StatefulWidget {
  const TeloHome({super.key});

  @override
  State<TeloHome> createState() => _TeloHomeState();
}

class _TeloHomeState extends State<TeloHome> {
  Room? _room;

  bool _connected = false;
  bool _connecting = false;

  String _status = 'Disconnected';
  String _agentState = 'idle';
  String _agentMessage = 'Ready';
  String _transcript = '';
  bool _transcriptFinal = false;

  @override
  void initState() {
    super.initState();

    // Listen for screen data coming from the
    // native Android AccessibilityService.
    AndroidBridge.setupScreenListener(
      _handleAccessibilityScreen,
    );
    AndroidBridge.setupActionResultListener(
      _handleAccessibilityActionResult,
    );
  }

  @override
  void dispose() {
    AndroidBridge.removeScreenListener();
    AndroidBridge.removeActionResultListener();

    _room?.dispose();

    super.dispose();
  }

  // ============================================================
  // CONNECT TO LIVEKIT
  // ============================================================

  Future<void> _connect() async {
    if (_connecting || _connected) {
      return;
    }

    setState(() {
      _connecting = true;
      _status = 'Connecting...';
    });

    try {
      // Ask our local backend for a LiveKit token.
      final response = await http.get(
        Uri.parse('$tokenServerUrl/token'),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Token server returned '
          '${response.statusCode}: '
          '${response.body}',
        );
      }

      final data =
          jsonDecode(response.body) as Map<String, dynamic>;

      final serverUrl = data['serverUrl'] as String;
      final token = data['token'] as String;

      // Create LiveKit room with roomOptions in constructor.
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );

      room.addListener(_onRoomChanged);

      // Listen for data coming from the AI agent.
      room.events.listen((event) {
        if (event is DataReceivedEvent) {
          _handleData(event.data, event.topic);
        } else if (event is TranscriptionEvent) {
          _handleTranscription(event, room);
        }
      });

      // Connect to LiveKit.
      await room.connect(
        serverUrl,
        token,
      );

      // Enable microphone.
      final participant = room.localParticipant;

      if (participant != null) {
        await participant.setMicrophoneEnabled(true);
      }

      // Tell Android this is an active microphone session before the user
      // switches apps. Its ongoing notification keeps the process eligible to
      // continue the LiveKit connection in the background.
      await AndroidBridge.startBackgroundSession();

      setState(() {
        _room = room;
        _connected = true;
        _connecting = false;
        _status = 'Connected — speak now';
        _agentState = 'listening';
        _agentMessage = 'Listening...';
      });
    } catch (e) {
      setState(() {
        _connecting = false;
        _connected = false;
        _status = 'Connection failed: $e';
      });
    }
  }

  // ============================================================
  // ROOM STATE
  // ============================================================

  void _onRoomChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  // ============================================================
  // DATA RECEIVED FROM PYTHON AGENT
  // ============================================================

  Future<void> _handleData(List<int> data, String? topic) async {
    try {
      final decoded = jsonDecode(
        utf8.decode(data),
      );

      if (decoded is! Map<String, dynamic>) {
        return;
      }

      if (topic == 'telo.status' || decoded['type'] == 'telo_status') {
        _handleStatus(decoded);
        return;
      }

      if (topic == 'telo.android' && decoded['type'] == 'android_action') {
        // Android owns UI automation. Flutter simply forwards the exact
        // structured command and later relays its result to the agent.
        await AndroidBridge.executeAccessibilityAction(
          jsonEncode(decoded),
        );

      }
    } catch (e) {
      debugPrint(
        'Data packet error: $e',
      );
    }
  }

  void _handleStatus(Map<String, dynamic> status) {
    if (!mounted) return;
    final state = status['state'] is String ? status['state'] as String : 'idle';
    final message = status['message'] is String && (status['message'] as String).trim().isNotEmpty
        ? status['message'] as String
        : _friendlyState(state);
    setState(() {
      _agentState = state;
      _agentMessage = message;
    });
  }

  void _handleTranscription(TranscriptionEvent event, Room room) {
    if (event.participant.identity != room.localParticipant?.identity) return;
    final text = event.segments.map((segment) => segment.text).where((text) => text.trim().isNotEmpty).join(' ').trim();
    if (text.isEmpty || !mounted) return;
    setState(() {
      _transcript = text;
      _transcriptFinal = event.segments.every((segment) => segment.isFinal);
      _agentState = _transcriptFinal ? 'thinking' : 'transcribing';
      _agentMessage = _transcriptFinal ? 'Understanding your voice...' : 'Listening...';
    });
  }

  String _friendlyState(String state) {
    const messages = <String, String>{
      'idle': 'Ready', 'listening': 'Listening...', 'transcribing': 'Understanding your voice...',
      'thinking': 'Thinking...', 'planning': 'Planning...', 'executing': 'Working...',
      'opening_app': 'Opening YouTube...', 'reading_screen': 'Checking the screen...',
      'finding_element': 'Finding what you asked for...', 'tapping': 'Opening it...',
      'typing': 'Typing...', 'searching': 'Searching...', 'swiping': 'Swiping...',
      'verifying': 'Checking that it worked...', 'success': 'Done', 'error': 'Something went wrong',
    };
    return messages[state] ?? 'Working...';
  }

  // ============================================================
  // ACCESSIBILITY SCREEN RECEIVED FROM ANDROID
  // ============================================================

  Future<void> _handleAccessibilityScreen(
    String screenData,
  ) async {
    debugPrint(
      'Accessibility screen received',
    );

    // If LiveKit isn't connected, there is
    // nowhere to send the screen data.
    if (!_connected) {
      debugPrint(
        'Cannot send screen: '
        'LiveKit is not connected.',
      );

      return;
    }

    final room = _room;

    if (room == null) {
      debugPrint(
        'Cannot send screen: Room is null.',
      );

      return;
    }

    // IMPORTANT:
    // localParticipant is nullable in the current
    // livekit_client version.
    final participant = room.localParticipant;

    if (participant == null) {
      debugPrint(
        'Cannot send screen: '
        'LiveKit participant is not ready.',
      );

      return;
    }

    try {
      final bytes = utf8.encode(screenData);

      // Send Android accessibility tree
      // back to the Python agent.
      await participant.publishData(
        bytes,
        reliable: true,
        topic: 'telo.screen',
      );

      debugPrint(
        'Accessibility screen sent to agent.',
      );
    } catch (e) {
      debugPrint(
        'Failed to send screen data: $e',
      );
    }
  }

  Future<void> _handleAccessibilityActionResult(
    String resultData,
  ) async {
    final room = _room;
    final participant = room?.localParticipant;

    if (!_connected || participant == null) {
      debugPrint('Cannot send Android action result: LiveKit is disconnected.');
      return;
    }

    try {
      await participant.publishData(
        utf8.encode(resultData),
        reliable: true,
        topic: 'telo.action_result',
      );
    } catch (e) {
      debugPrint('Failed to send Android action result: $e');
    }
  }

  // ============================================================
  // DISCONNECT
  // ============================================================

  Future<void> _disconnect() async {
    try {
      await _room?.disconnect();
    } catch (e) {
      debugPrint(
        'Disconnect error: $e',
      );
    }

    await AndroidBridge.stopBackgroundSession();

    if (!mounted) {
      return;
    }

    setState(() {
      _connected = false;
      _connecting = false;
      _status = 'Disconnected';
      _agentState = 'idle';
      _agentMessage = 'Ready';
      _transcript = '';
      _transcriptFinal = false;
    });
  }

  IconData _iconForState(String state) {
    switch (state) {
      case 'listening':
        return Icons.mic_rounded;
      case 'transcribing':
        return Icons.record_voice_over_rounded;
      case 'thinking':
      case 'planning':
        return Icons.psychology_rounded;
      case 'opening_app':
        return Icons.open_in_new_rounded;
      case 'reading_screen':
      case 'finding_element':
        return Icons.search_rounded;
      case 'tapping':
        return Icons.touch_app_rounded;
      case 'typing':
        return Icons.keyboard_rounded;
      case 'searching':
        return Icons.manage_search_rounded;
      case 'swiping':
        return Icons.swipe_rounded;
      case 'verifying':
        return Icons.fact_check_rounded;
      case 'success':
        return Icons.check_circle_rounded;
      case 'error':
        return Icons.error_outline_rounded;
      case 'recovery':
        return Icons.sync_problem_rounded;
      default:
        return Icons.smart_toy_rounded;
    }
  }

  Color _colorForState(String state) {
    switch (state) {
      case 'listening':
      case 'transcribing':
        return const Color(0xFFFFC107);
      case 'thinking':
      case 'planning':
      case 'verifying':
        return const Color(0xFF64B5F6);
      case 'opening_app':
      case 'tapping':
      case 'typing':
      case 'searching':
      case 'swiping':
      case 'executing':
        return const Color(0xFF81C784);
      case 'success':
        return const Color(0xFF4CAF50);
      case 'error':
        return const Color(0xFFE57373);
      case 'recovery':
        return const Color(0xFFFFB74D);
      default:
        return Colors.white70;
    }
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final stateColor = _colorForState(_agentState);
    final isBusy = _connected && _agentState != 'idle' && _agentState != 'success';

    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 16),

              // ------------------------------------------------
              // TELO ORB
              // ------------------------------------------------

              AnimatedContainer(
                duration: const Duration(
                  milliseconds: 500,
                ),
                width: _connected ? 130 : 110,
                height: _connected ? 130 : 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _connected
                      ? stateColor
                      : const Color(0xFF202020),
                  boxShadow: _connected
                      ? [
                          BoxShadow(
                            color: stateColor.withValues(
                              alpha: .25,
                            ),
                            blurRadius: 50,
                            spreadRadius: 10,
                          ),
                        ]
                      : [],
                ),
                child: Icon(
                  _connected ? _iconForState(_agentState) : Icons.graphic_eq_rounded,
                  size: 56,
                  color: _connected
                      ? Colors.black
                      : Colors.white70,
                ),
              ),

              const SizedBox(
                height: 24,
              ),

              // ------------------------------------------------
              // TITLE & CONNECTION STATE
              // ------------------------------------------------

              const Text(
                'TELO',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 5,
                ),
              ),

              const SizedBox(
                height: 6,
              ),

              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _connected ? const Color(0xFF4CAF50) : Colors.white30,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // ------------------------------------------------
              // REALTIME ACTION / STATUS CARD
              // ------------------------------------------------

              if (_connected)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: stateColor.withValues(alpha: 0.3),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isBusy) ...[
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(stateColor),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Flexible(
                          child: Text(
                            _agentMessage,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: stateColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ------------------------------------------------
              // LIVE TRANSCRIPT CARD
              // ------------------------------------------------

              if (_connected && _transcript.isNotEmpty) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.record_voice_over_rounded,
                              size: 14,
                              color: _transcriptFinal ? Colors.white70 : const Color(0xFFFFC107),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _transcriptFinal ? 'You said' : 'Listening...',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _transcriptFinal ? Colors.white54 : const Color(0xFFFFC107),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '"$_transcript"',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: _transcriptFinal ? 0.95 : 0.75),
                            fontStyle: _transcriptFinal ? FontStyle.normal : FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const Spacer(),

              // ------------------------------------------------
              // CONNECT BUTTON
              // ------------------------------------------------

              Padding(
                padding: const EdgeInsets.all(28),
                child: SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: FilledButton.icon(
                    onPressed: _connected
                        ? _disconnect
                        : _connect,
                    icon: Icon(
                      _connected
                          ? Icons.stop_rounded
                          : Icons.mic_rounded,
                    ),
                    label: Text(
                      _connected
                          ? 'Disconnect'
                          : 'Connect & Talk',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================================================================
// ANDROID BRIDGE
// ==================================================================

/// Bridge between Flutter and native Android.
///
/// Flutter -> Android:
///
///     executeAccessibilityAction (structured JSON)
///
/// Android -> Flutter:
///
///     accessibilityScreen and accessibilityActionResult
///
class AndroidBridge {
  static const MethodChannel _channel =
      MethodChannel('telo/android');
  static Future<void> Function(String)? _screenCallback;
  static Future<void> Function(String)? _actionResultCallback;
  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      final data = call.arguments;
      if (data is! String) return;
      if (call.method == 'accessibilityScreen') {
        await _screenCallback?.call(data);
      } else if (call.method == 'accessibilityActionResult') {
        await _actionResultCallback?.call(data);
      }
    });
  }

  // --------------------------------------------------------------
  // SCREEN LISTENER
  // --------------------------------------------------------------

  static Future<void> setupScreenListener(
    Future<void> Function(
      String screenData,
    ) callback,
  ) async {
    _screenCallback = callback;
    _installHandler();
  }

  static Future<void> setupActionResultListener(
    Future<void> Function(String resultData) callback,
  ) async {
    _actionResultCallback = callback;
    _installHandler();
  }

  // --------------------------------------------------------------
  // REMOVE LISTENER
  // --------------------------------------------------------------

  static void removeScreenListener() {
    _screenCallback = null;
  }

  static void removeActionResultListener() => _actionResultCallback = null;

  // --------------------------------------------------------------
  static Future<void> executeAccessibilityAction(String command) async {
    try {
      await _channel.invokeMethod('executeAccessibilityAction', {
        'command': command,
      });
    } catch (e) {
      debugPrint('executeAccessibilityAction error: $e');
    }
  }

  static Future<void> startBackgroundSession() async {
    try {
      await _channel.invokeMethod('startBackgroundSession');
    } catch (e) {
      debugPrint('Unable to start background session: $e');
    }
  }

  static Future<void> stopBackgroundSession() async {
    try {
      await _channel.invokeMethod('stopBackgroundSession');
    } catch (e) {
      debugPrint('Unable to stop background session: $e');
    }
  }
}
