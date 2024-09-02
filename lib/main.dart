import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:window_size/window_size.dart';
import 'dart:io';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    setWindowTitle('Scrcpy Flutter Windows');
    setWindowMinSize(const Size(600, 400));
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const MaterialAppWithTheme();
  }
}

class MaterialAppWithTheme extends StatefulWidget {
  const MaterialAppWithTheme({Key? key}) : super(key: key);

  @override
  _MaterialAppWithThemeState createState() => _MaterialAppWithThemeState();
}

class _MaterialAppWithThemeState extends State<MaterialAppWithTheme> {
  ThemeMode _themeMode = ThemeMode.system;

  void _toggleThemeMode(bool isDarkMode) {
    setState(() {
      _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scrcpy Flutter Windows',
      theme: ThemeData(primarySwatch: Colors.blue),
      darkTheme: ThemeData.dark(),
      themeMode: _themeMode,
      home: ScrcpyPage(
        onToggleThemeMode: _toggleThemeMode,
        isDarkMode: _themeMode == ThemeMode.dark,
      ),
    );
  }
}

class ScrcpyPage extends StatefulWidget {
  final void Function(bool) onToggleThemeMode;
  final bool isDarkMode;

  const ScrcpyPage({Key? key, required this.onToggleThemeMode, required this.isDarkMode}) : super(key: key);

  @override
  _ScrcpyPageState createState() => _ScrcpyPageState();
}

class _ScrcpyPageState extends State<ScrcpyPage> {
  String? _scrcpyPath;
  List<String> _log = [];
  Process? _scrcpyProcess;
  bool _isMirroring = false;
  bool _isRecording = false;

  // New options for recording and wireless
  bool _enableRecording = false;
  String _recordingPath = '';
  bool _enableWireless = false;
  String _deviceIp = '';

  // Custom recording name
  String _customRecordingName = '';

  @override
  void initState() {
    super.initState();
    _prepareScrcpyExecutable();
  }

  Future<void> _prepareScrcpyExecutable() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final List<String> files = [
        'adb.exe',
        'AdbWinApi.dll',
        'AdbWinUsbApi.dll',
        'avcodec-61.dll',
        'avformat-61.dll',
        'avutil-59.dll',
        'desktop.ini',
        'icon.png',
        'libusb-1.0.dll',
        'open_a_terminal_here.bat',
        'scrcpy.exe',
        'scrcpy-console.bat',
        'scrcpy-noconsole.vbs',
        'scrcpy-server',
        'SDL2.dll',
        'swresample-5.dll',
      ];

      for (String file in files) {
        final byteData = await rootBundle.load('assets/$file');
        final extractedFile = File('${tempDir.path}/$file');
        await extractedFile.writeAsBytes(byteData.buffer.asUint8List());
      }

      setState(() {
        _scrcpyPath = '${tempDir.path}/scrcpy.exe';
      });

      _addLog('scrcpy.exe and dependencies extracted to: ${tempDir.path}');
    } catch (e) {
      _addLog('Failed to extract scrcpy.exe and dependencies: $e');
    }
  }

  Future<void> _setRecordingPath() async {
    try {
      final directory = Directory('${Platform.environment['USERPROFILE']}\\Videos');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      if (_customRecordingName.isEmpty) {
        _showErrorDialog('Error', 'Please provide a custom recording name.');
        return;
      }

      setState(() {
        _recordingPath = '${directory.path}\\$_customRecordingName.mkv';
      });

      _addLog('Recording will be saved as: $_recordingPath');
    } catch (e) {
      _addLog('Failed to set recording path: $e');
    }
  }

  Future<void> _startScrcpy() async {
    if (_scrcpyPath == null) {
      _addLog('scrcpy.exe is not ready.');
      return;
    }

    await _setRecordingPath();

    if (_recordingPath.isEmpty && _enableRecording) {
      return;
    }

    setState(() {
      _isMirroring = true;
    });

    _addLog('Starting scrcpy...');

    try {
      List<String> arguments = [];

      if (_enableWireless) {
        await Process.run('adb', ['tcpip', '5555']);

        _deviceIp = (await _getDeviceIp()) ?? ''; // Ensure there's a semicolon here
      if (_deviceIp.isEmpty) {
        _showErrorDialog('Error', 'Failed to detect device IP. Ensure the device is connected over Wi-Fi.');
        setState(() {
          _isMirroring = false;
        });
        return;
      }


        final connectResult = await Process.run('adb', ['connect', '$_deviceIp:5555']);
        if (connectResult.exitCode != 0) {
          _showErrorDialog('Error', 'Failed to connect to the device over Wi-Fi: ${connectResult.stderr}');
          setState(() {
            _isMirroring = false;
          });
          return;
        }
        _addLog('Connected to device wirelessly: $_deviceIp');
      }

      if (_enableRecording && _recordingPath.isNotEmpty) {
        arguments.addAll(['--record', _recordingPath]);
        _addLog('Recording to: $_recordingPath');
        setState(() {
          _isRecording = true;
        });
      }

      _scrcpyProcess = await Process.start(_scrcpyPath!, arguments);
      _scrcpyProcess!.stdout.transform(utf8.decoder).listen(_addLog);
      _scrcpyProcess!.stderr.transform(utf8.decoder).listen(_addLog);
      _addLog('scrcpy started.');
    } catch (e) {
      _addLog('Failed to start scrcpy: $e');
      setState(() {
        _isMirroring = false;
      });
    }
  }

  Future<String?> _getDeviceIp() async {
    try {
      final result = await Process.run('adb', ['shell', 'ip', 'route']);
      final output = result.stdout as String;

      // Parse IP from the output
      final ipPattern = RegExp(r'(\d+\.\d+\.\d+\.\d+) via');
      final match = ipPattern.firstMatch(output);
      if (match != null) {
        return match.group(1);
      }

      _addLog('IP address not found in route info.');
    } catch (e) {
      _addLog('Failed to get device IP: $e');
    }

    // Fallback: Attempt to list all connected devices and use one
    final devicesResult = await Process.run('adb', ['devices']);
    final devicesOutput = devicesResult.stdout as String;
    final deviceIpPattern = RegExp(r'(\d+\.\d+\.\d+\.\d+):5555');
    final deviceMatch = deviceIpPattern.firstMatch(devicesOutput);
    if (deviceMatch != null) {
      return deviceMatch.group(1);
    }

    _addLog('No connected wireless device IP found.');
    return null;
  }

  void _stopScrcpy() {
    if (_scrcpyProcess != null) {
      _scrcpyProcess!.kill();
      _scrcpyProcess = null;
      _addLog('scrcpy stopped.');

      if (_isRecording) {
        _addLog('Recording saved to: $_recordingPath');
        setState(() {
          _isRecording = false;
        });
      }
    }

    setState(() {
      _isMirroring = false;
    });
  }

  void _addLog(String message) {
    setState(() {
      _log.add(message);
    });
  }

  void _clearLog() {
    setState(() {
      _log.clear();
    });
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  bool _isValidRecordingName(String name) {
    final invalidCharacters = RegExp(r'[<>:"/\\|?*]');
    return !invalidCharacters.hasMatch(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MirrorX'),
        centerTitle: true,  // Center the title and toggle button
        actions: [
          Tooltip(
            message: 'Switch Theme',
            child: Switch(
              value: widget.isDarkMode,
              onChanged: (value) => widget.onToggleThemeMode(value),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Custom Recording Name (Optional)',
                hintText: 'Enter recording name',
              ),
              onChanged: (value) {
                if (_isValidRecordingName(value)) {
                  setState(() {
                    _customRecordingName = value;
                  });
                } else {
                  _showErrorDialog('Invalid Name', 'The recording name contains invalid characters.');
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Enable Wireless:'),
                Switch(
                  value: _enableWireless,
                  onChanged: (value) {
                    setState(() {
                      _enableWireless = value;
                    });
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Enable Recording:'),
                Switch(
                  value: _enableRecording,
                  onChanged: (value) {
                    setState(() {
                      _enableRecording = value;
                    });
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _isMirroring ? null : _startScrcpy,
                  child: const Text('Start Mirroring'),
                ),
                ElevatedButton(
                  onPressed: _isMirroring ? _stopScrcpy : null,
                  child: const Text('Stop Mirroring'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (BuildContext context, int index) {
                return ListTile(
                  title: Text(_log[index]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _clearLog,
        child: const Icon(Icons.clear),
        tooltip: 'Clear Log',
      ),
    );
  }
}
