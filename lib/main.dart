import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:universal_html/html.dart' as html; // 👈 『dart:html』からこれに書き換える！

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI English Tutor Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xff4a90e2),
        scaffoldBackgroundColor: const Color(0xfff5f7fa),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final TextEditingController _apiKeyController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isListening = false;
  String _interimText = '';
  String _statusText = '待機中...';
  double _speed = 0.9;
  bool _showText = true;
  bool _showHint = false;

  final List<Map<String, String>> _messages = [];
  final List<Map<String, String>> _apiHistory = [
    {
      "role": "system",
      "content": "You are a friendly English teacher. Keep responses concise (1-3 sentences). After each user response, if they made a significant grammatical error, briefly provide a correction in the format: [Correction: ...]. Then continue the conversation."
    }
  ];

  @override
  void initState() {
    super.initState();
    _initSpeechAndTts();
    _messages.add({
      'role': 'ai',
      'text': "Hello! Let's practice English. Press the button to start speaking, and press it again when you're finished.",
      'hint': ''
    });
  }

  // 🛠️ Web（Safari）でも綺麗に動くように初期化をシンプル化
  void _initSpeechAndTts() async {
    try {
      await _speech.initialize(
        onError: (val) => setState(() { _statusText = 'エラーが発生しました'; _isListening = false; }),
      );
      
      // アプリ専用の設定を削除し、言語設定だけにします
      await _tts.setLanguage("en-US");
    } catch (e) {
      debugPrint("Initialization error: $e");
    }
  }


  void _toggleListening() async {
    if (!_isListening) {
      // すでに initState で initialize は終わっているので、
      // _speech.isAvailable（利用可能か）をチェックするだけにします
      if (_speech.isAvailable) {
        setState(() {
          _isListening = true;
          _interimText = '';
          _statusText = '聞き取り中...（どれだけ止まっても大丈夫です）';
        });
        _speech.listen(
          localeId: 'en_US',
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 10),
          onResult: (val) {
            setState(() {
              _interimText = val.recognizedWords;
            });
          },
        );
      } else {
        setState(() { _statusText = 'マイクが準備できていません'; });
      }
    } else {
      await _speech.stop();
      _handleUserSpeech(_interimText);
    }
  }

  void _handleUserSpeech(String text) async {
    if (text.trim().isEmpty) return;

    final apiKey = _apiKeyController.text;
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('APIキーを入力してください')));
      setState(() { _isListening = false; _statusText = '待機中...'; });
      return;
    }

    setState(() {
      _isListening = false;
      _messages.add({'role': 'user', 'text': text, 'hint': ''});
      _apiHistory.add({'role': 'user', 'content': text});
      _interimText = '';
      _statusText = 'AIが考えています...';
    });
    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': _apiHistory,
        }),
      );

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final reply = data['choices'][0]['message']['content'] as String;

      String hint = '';
      if (_showHint) {
        hint = await _getJapaneseHint(reply, apiKey);
      }

      setState(() {
        _apiHistory.add({'role': 'assistant', 'content': reply});
        _messages.add({'role': 'ai', 'text': reply, 'hint': hint});
        _statusText = '待機中...';
      });
      _scrollToBottom();

      String speakText = reply.replaceAll(RegExp(r'\[Correction: .*?\]'), '');
      _speak(speakText);

    } catch (e) {
      setState(() { _statusText = 'エラーが発生しました'; });
    }
  }

  Future<String> _getJapaneseHint(String text, String apiKey) async {
    try {
      final res = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini',
          'messages': [
            {'role': 'system', 'content': 'Translate to natural Japanese.'},
            {'role': 'user', 'content': text}
          ],
        }),
      );
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      return data['choices'][0]['message']['content'];
    } catch (e) {
      return '翻訳エラー';
    }
  }

void _speak(String text) async {
    final apiKey = _apiKeyController.text;
    if (apiKey.isEmpty) return;

    setState(() { _statusText = '音声を生成中...'; });

    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/audio/speech'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'tts-1',
          'input': text,
          'voice': 'alloy',
          'speed': _speed,
        }),
      );

      if (response.statusCode == 200) {
        final blob = html.Blob([response.bodyBytes], 'audio/mp3');
        final url = html.Url.createObjectUrlFromBlob(blob);
        final audio = html.AudioElement(url);
        
        // 💡 AIの音声が話し終わったら、自動的にマイクの聞き取り（_toggleListening）を呼び出す
        audio.onEnded.listen((event) {
          Future.delayed(const Duration(milliseconds: 400), () {
            // すでに聞き取り中でない場合（_isListening == false）のみ自動でマイクをONにする
            if (!_isListening) {
              _toggleListening(); 
            }
          });
        });

        audio.play();
        setState(() { _statusText = 'AIが話し中...'; });
      } else {
        setState(() { _statusText = '音声生成エラー'; });
      }
    } catch (e) {
      setState(() { _statusText = '音声再生に失敗しました'; });
    }
  }

  void _repeatLast() {
    final aiMsgs = _messages.where((m) => m['role'] == 'ai').toList();
    if (aiMsgs.isNotEmpty) {
      String cleanText = aiMsgs.last['text']!.replaceAll(RegExp(r'\[Correction: .*?\]'), '');
      _speak(cleanText);
    }
  }

  void _clearChat() {
    setState(() {
      _messages.clear();
      _apiHistory.removeRange(1, _apiHistory.length);
      _messages.add({
        'role': 'ai',
        'text': "Hello! Let's practice English. Press the button to start speaking, and press it again when you're finished.",
        'hint': ''
      });
      _statusText = 'クリアしました';
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI English Tutor Pro', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xff4a90e2),
        centerTitle: true,
        elevation: 2,
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                TextField(
                  controller: _apiKeyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'OpenAI API Keyを入力',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.all(8),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Row(
                      children: [
                        const Text('速度: '),
                        Slider(
                          value: _speed,
                          min: 0.5,
                          max: 1.2,
                          onChanged: (val) {
                            setState(() { _speed = val; });
                          },
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Checkbox(
                          value: _showText,
                          onChanged: (val) => setState(() { _showText = val ?? true; }),
                        ),
                        const Text('英文表示'),
                      ],
                    ),
                    Row(
                      children: [
                        Checkbox(
                          value: _showHint,
                          onChanged: (val) => setState(() { _showHint = val ?? false; }),
                        ),
                        const Text('ヒント'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(20),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = (msg['role'] == 'user');
                final text = msg['text'] ?? '';
                final String hint = msg['hint']?.toString() ?? '';

                String displayText = text;
                String correctionText = '';
                if (text.isNotEmpty) {
                  final regExp = RegExp(r'\[Correction: (.*?)\]');
                  final match = regExp.firstMatch(text);
                  if (match != null) {
                    displayText = text.replaceFirst(regExp, '');
                    correctionText = match.group(1) ?? '';
                  }
                }

                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xffe1ffc7) : Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(15),
                        topRight: const Radius.circular(15),
                        bottomLeft: isUser ? const Radius.circular(15) : const Radius.circular(2),
                        bottomRight: isUser ? const Radius.circular(2) : const Radius.circular(15),
                      ),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withAlpha(26), blurRadius: 2, offset: const Offset(0, 1))
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (!isUser && !_showText) ? '（英文非表示）' : displayText,
                          style: TextStyle(
                            fontSize: 16, 
                            height: 1.5,
                            color: (!isUser && !_showText) ? Colors.grey : Colors.black
                          ),
                        ),
                        if (correctionText.isNotEmpty) ...[
                          const Divider(height: 15, color: Colors.redAccent),
                          Text('💡 $correctionText', style: const TextStyle(fontSize: 14, color: Colors.red)),
                        ],
                        if (hint.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(hint, style: const TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic)),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(_statusText, style: const TextStyle(color: Colors.grey)),
                if (_interimText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(_interimText, style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
                  ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isListening ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      onPressed: _toggleListening,
                      child: Text(_isListening ? '話し終わったらタップ' : 'タップして話す'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.grey, foregroundColor: Colors.white),
                      onPressed: _repeatLast,
                      child: const Text('もう一度聞く'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                      onPressed: _clearChat,
                      child: const Text('クリア'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}