import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// Cross link step types for step-by-step construction
enum CrossLinkStepType {
  sourceSlot,
  sourceReport,
  sourceValue,
  targetSlot,
  targetCommand,
  targetValue,
}

void main() {
  runApp(const ModuleBoxApp());
}

class ModuleBoxApp extends StatelessWidget {
  const ModuleBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'moduleBox Discovery',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class DeviceItem {
  DeviceItem({
    required this.displayName,
    required this.kind,
    required this.identifier,
    required this.extra,
  });

  final String displayName; // e.g. MyBox (ttyUSB0)
  final String kind; // "serial" | "mdns"
  final String identifier; // e.g. /dev/ttyUSB0 or 192.168.1.5:9000
  final Map<String, Object?> extra; // any details
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final List<DeviceItem> _devices = <DeviceItem>[];
  DeviceItem? _selected;
  bool _isScanning = false;
  final List<String> _logs = <String>[];
  final ScrollController _logsScrollController = ScrollController();
  final ScrollController _suggestionScrollController = ScrollController();
  final TextEditingController _configEditorController = TextEditingController();
  final FocusNode _configEditorFocusNode = FocusNode();
  final ScrollController _textEditorScrollController = ScrollController();
  Timer? _autocompleteTimer;
  Timer? _overlayTimer;
  Timer? _consoleAutocompleteTimer;
  String _lastText = '';
  TextSelection? _lastSelection;
  List<String> _cachedSuggestions = [];
  String? _currentWord;
  List<String> _currentSuggestions = [];
  OverlayEntry? _suggestionOverlay;
  int _selectedSuggestionIndex = -1;
  // Console autocomplete state
  final FocusNode _consoleInputFocusNode = FocusNode();
  // Save button long-press state
  bool _isSaveButtonLongPressed = false;
  List<String> _consoleSuggestions = [];
  String? _consoleCurrentWord;
  OverlayEntry? _consoleSuggestionOverlay;
  int _consoleSelectedSuggestionIndex = -1;
  // Cache for current mode to avoid repeated parsing during description lookups
  String? _cachedCurrentMode;
  bool _isRebuilding = false;
  bool _isLayoutInProgress = false;
  // Cached files loaded from removable drives when serial device is selected
  String? _cachedManifestContent; // TODO: Use for device manifest display
  String? _cachedConfigContent;
  String? _cachedManifestPath; // TODO: Use for device manifest display  
  String? _cachedConfigPath;
  
  // Configuration parsing
  Map<String, Map<String, String>> _parsedConfig = {};
  Map<String, Map<String, String>> _originalParsedConfig = {};
  String? _selectedChapter;
  final Map<String, TextEditingController> _configControllers = {};
  bool _isConfigEditorDirty = false;
  bool _isConfigDesignDirty = false;
  bool _suspendEditorDirtyTracking = false;
  bool _suspendDesignDirtyTracking = false;
  late final TabController _detailsTabController;
  int _currentDetailsTabIndex = 0;
  
  // Manifest parsing for key suggestions
  Map<String, dynamic> _manifestData = {};
  Map<String, List<String>> _availableKeys = {};
  Map<String, String> _chapterDescriptions = {};
  Map<String, String> _chapterWildcards = {}; // Maps wildcard patterns to actual chapter names
  List<String> get _removableRoots {
    if (Platform.isWindows) {
      // Windows: Check all available drive letters
      return <String>[
        'D:\\',
        'E:\\',
        'F:\\',
        'G:\\',
        'H:\\',
        'I:\\',
        'J:\\',
        'K:\\',
      ];
    } else {
      // Linux and macOS
      return <String>[
        '/media',
        '/mnt',
        '/Volumes',
      ];
    }
  }

  void _log(String message) {
    final String time = DateTime.now().toIso8601String().substring(11, 19);
    final String logMessage = '$time  $message';
    
    // Print to console
    print(logMessage);
    
    setState(() {
      _logs.add(logMessage);
      if (_logs.length > 1000) {
        _logs.removeRange(0, _logs.length - 1000);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _detailsTabController = TabController(length: 3, vsync: this);
    _detailsTabController.addListener(_handleDetailsTabChange);
    _setupAutocompleteListener();
    _setupConsoleAutocompleteListener();
    _startScan();
  }

  @override
  void setState(VoidCallback fn) {
    _isRebuilding = true;
    super.setState(fn);
    _isRebuilding = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isLayoutInProgress = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isLayoutInProgress = false;
    });
  }

  /// Setup autocomplete listener for text changes
  void _setupAutocompleteListener() {
    _configEditorController.addListener(() {
      // Safety check to prevent assertion failures during widget rebuilds
      if (!mounted) return;
      final String currentText = _configEditorController.text;
      final TextSelection currentSelection = _configEditorController.selection;

      if (_suspendEditorDirtyTracking) {
        _lastText = currentText;
        _lastSelection = currentSelection;
        return;
      }
      
      // Check if selection changed without text changing (mouse click)
      if (currentText == _lastText && 
          _lastSelection != null && 
          currentSelection != _lastSelection &&
          _suggestionOverlay != null) {
        _hideSuggestionOverlay();
        _lastSelection = currentSelection;
        return;
      }
      
      if (currentText != _lastText) {
        _refreshEditorDirtyState(currentText: currentText);
        // Check if mode= was changed by comparing mode values in all SLOT chapters
        bool modeChanged = _detectModeChange(_lastText, currentText);
        
        _lastText = currentText;
        _lastSelection = currentSelection;
        // Clear cached suggestions when text changes to refresh chapter suggestions
        _cachedSuggestions.clear();
        _autocompleteTimer?.cancel();
        _autocompleteTimer = Timer(const Duration(milliseconds: 150), () {
          if (mounted) {
            _updateAutocompleteSuggestions();
            // If mode changed and user is typing cross_link=, refresh suggestions
            if (modeChanged) {
              Future.microtask(() {
                if (mounted) {
                  _updateAutocompleteSuggestions();
                }
              });
            }
          }
        });
      } else {
        _lastSelection = currentSelection;
      }
    });
  }

  void _handleDetailsTabChange() {
    if (!_detailsTabController.indexIsChanging && _detailsTabController.index != _currentDetailsTabIndex) {
      _currentDetailsTabIndex = _detailsTabController.index;
      if (_currentDetailsTabIndex == 0) {
        _syncEditorFromParsedConfig();
      } else if (_currentDetailsTabIndex == 1) {
        _refreshParsedConfigFromEditor();
      }
    }
  }

  /// Setup autocomplete listener for console input (crosslink suggestions starting from targetSlot)
  void _setupConsoleAutocompleteListener() {
    _consoleInputController.addListener(() {
      if (!mounted) return;
      
      // Cancel any pending timer
      _consoleAutocompleteTimer?.cancel();
      
      final String currentText = _consoleInputController.text;
      
      // Trigger suggestions based on patterns (without requiring "->")
      // Pattern 1: Just text -> show target slots
      // Pattern 2: "slot/" -> show target commands
      // Pattern 3: "slot/command:" -> show target values
      
      if (currentText.isNotEmpty) {
        // Delay to avoid showing suggestions during rapid typing
        _consoleAutocompleteTimer = Timer(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          
          final List<String> suggestions = _getConsoleCrossLinkSuggestions(currentText);
          if (suggestions.isNotEmpty) {
            setState(() {
              _consoleSuggestions = suggestions;
              _consoleCurrentWord = currentText;
            });
            // Use Future.microtask to ensure widget tree is ready
            Future.microtask(() {
              if (mounted) {
                _showConsoleSuggestionOverlay(suggestions, currentText);
              }
            });
          } else {
            _hideConsoleSuggestionOverlay();
          }
        });
      } else {
        _hideConsoleSuggestionOverlay();
      }
    });
  }

  /// Get crosslink suggestions for console input (starting from targetSlot step, without "->" trigger)
  List<String> _getConsoleCrossLinkSuggestions(String input) {
    final List<String> suggestions = <String>[];
    
    if (input.isEmpty) return suggestions;
    
    // Check if input contains "/" (indicating we might be looking for commands)
    if (input.contains('/')) {
      final List<String> parts = input.split('/');
      if (parts.length >= 2) {
        final String slotPart = parts[0];
        final String afterSlash = parts[1];
        
        // Check if after "/" contains ":" (indicating we're looking for values)
        if (afterSlash.contains(':')) {
          // Pattern: "slot/command:" -> show target values
          final List<String> valueParts = afterSlash.split(':');
          final String valueFilter = valueParts.length > 1 ? valueParts[1] : '';
          
          final List<String> topicValues = _getTopicValuesFromSlotSilent(slotPart);
          for (final String value in topicValues) {
            if (valueFilter.isEmpty || value.toLowerCase().contains(valueFilter.toLowerCase())) {
              if (value.toLowerCase() != valueFilter.toLowerCase()) {
                suggestions.add(value);
              }
            }
          }
        } else {
          // Pattern: "slot/" -> show target commands
          final List<String> commands = _getTargetCommandsForSlot(slotPart);
          for (final String command in commands) {
            if (command.isNotEmpty) {
              if (afterSlash.isEmpty || command.toLowerCase().contains(afterSlash.toLowerCase())) {
                if (command.toLowerCase() != afterSlash.toLowerCase()) {
                  suggestions.add(command);
                }
              }
            }
          }
        }
      }
    } else {
      // Pattern: just text -> show target slots
      final List<String> targetSlots = _getTopicBasedSourceSlots();
      for (final String slot in targetSlots) {
        if (input.isEmpty || slot.toLowerCase().contains(input.toLowerCase())) {
          if (slot.toLowerCase() != input.toLowerCase()) {
            suggestions.add(slot);
          }
        }
      }
    }
    
    return suggestions;
  }

  void _refreshEditorDirtyState({String? currentText}) {
    final String baseline = _cachedConfigContent ?? '';
    final String comparedText = currentText ?? _configEditorController.text;
    final bool newDirty = _cachedConfigContent == null ? false : comparedText != baseline;

    if (_isConfigEditorDirty != newDirty) {
      if (mounted) {
        setState(() {
          _isConfigEditorDirty = newDirty;
        });
      } else {
        _isConfigEditorDirty = newDirty;
      }
    }
  }
  
  /// Detect if mode= value changed in any SLOT chapter
  bool _detectModeChange(String oldText, String newText) {
    if (oldText.isEmpty) return false;
    
    // Extract all mode values from old and new text
    Map<String, String?> oldModes = _extractAllModeValues(oldText);
    Map<String, String?> newModes = _extractAllModeValues(newText);
    
    // Check if any mode value changed
    for (final String chapter in newModes.keys) {
      final String? oldMode = oldModes[chapter];
      final String? newMode = newModes[chapter];
      if (oldMode != newMode) {
        return true;
      }
    }
    
    return false;
  }
  
  /// Extract all mode values from text for all SLOT chapters
  Map<String, String?> _extractAllModeValues(String text) {
    final Map<String, String?> modes = {};
    final List<String> lines = text.split('\n');
    String? currentChapter;
    
    for (final String line in lines) {
      final String trimmedLine = line.trim();
      
      // Check if this is a chapter header
      if (trimmedLine.startsWith('[') && trimmedLine.endsWith(']')) {
        final String chapter = trimmedLine.substring(1, trimmedLine.length - 1);
        if (chapter.startsWith('SLOT_')) {
          currentChapter = chapter;
          modes[currentChapter] = null; // Initialize
        } else {
          currentChapter = null;
        }
        continue;
      }
      
      // If we're in a SLOT chapter, look for mode= line
      if (currentChapter != null && trimmedLine.contains('=')) {
        final int equalIndex = trimmedLine.indexOf('=');
        if (equalIndex > 0) {
          final String key = trimmedLine.substring(0, equalIndex).trim();
          if (key.toLowerCase() == 'mode') {
            final String mode = trimmedLine.substring(equalIndex + 1).trim();
            modes[currentChapter] = mode;
          }
        }
      }
      
      // If we hit another chapter header, reset current chapter
      if (trimmedLine.startsWith('[') && trimmedLine.endsWith(']')) {
        currentChapter = null;
      }
    }
    
    return modes;
  }

  /// Update autocomplete suggestions based on current text
  void _updateAutocompleteSuggestions() {
    // Safety check to prevent assertion failures during widget rebuilds
    if (!mounted) return;
    
    final String text = _configEditorController.text;
    final int cursorPos = _configEditorController.selection.baseOffset;
    
    _log('DEBUG: _updateAutocompleteSuggestions called, cursorPos: $cursorPos, text length: ${text.length}');
    
    if (cursorPos <= 0 || text.isEmpty) {
      _hideSuggestionOverlay();
      if (mounted) {
        setState(() {
          _currentWord = null;
          _currentSuggestions = [];
        });
      }
      return;
    }

    // Find current word being typed (including special handling for mode=, options=, etc.)
    // For known keywords, we need to handle spaces around "=", so we'll scan from cursor backwards
    // to find the keyword and include everything up to cursor
    
    int start = cursorPos;
    int end = cursorPos;
    
    // First, try to find if we're in a known keyword context by looking backwards from cursor
    // Look for patterns like "mode", "mode=", "mode =", "mode = ", etc.
    int keywordStart = cursorPos;
    int lookBack = cursorPos;
    
    // Look backwards to find a known keyword (mode, options, cross_link)
    // Increase lookback limit to handle longer option values
    final int maxLookback = 200;
    while (lookBack > 0 && lookBack > cursorPos - maxLookback) {
      final char = text[lookBack - 1];
      if (char == '\n') break; // Stop at newline
      
      // Check if we've found a complete keyword
      final testWord = text.substring(lookBack - 1, cursorPos);
      final normalizedTest = _normalizeWordForComparison(testWord).toLowerCase();
      
      String? matchedKeyword;
      if (normalizedTest == 'mode' || normalizedTest.startsWith('mode=')) {
        matchedKeyword = 'mode';
      } else if (normalizedTest == 'options' || normalizedTest.startsWith('options=')) {
        matchedKeyword = 'options';
      } else if (normalizedTest == 'cross_link' || normalizedTest.startsWith('cross_link=')) {
        matchedKeyword = 'cross_link';
      }
      
      if (matchedKeyword != null) {
        // Found a keyword match, now find the actual start of the keyword
        int actualKeywordStart = lookBack - 1;
        
        // Look backwards to find the start of the keyword word
        for (int i = actualKeywordStart; i >= 0 && i > actualKeywordStart - 100; i--) {
          if (i < text.length) {
            final String checkText = text.substring(i, cursorPos);
            final String normalizedCheck = _normalizeWordForComparison(checkText).toLowerCase();
            
            if (normalizedCheck.startsWith(matchedKeyword)) {
              if (i == 0 || _isWordBoundaryForAutocomplete(text[i - 1])) {
                final String keywordFirstChar = matchedKeyword[0];
                if (i < text.length && text[i].toLowerCase() == keywordFirstChar) {
                  actualKeywordStart = i;
                  break;
                }
              }
            }
          }
        }
        
        keywordStart = actualKeywordStart;
        break;
      }
      
      lookBack--;
    }
    
    // If we found a keyword, use it; otherwise use normal word detection
    if (keywordStart < cursorPos) {
      // Found a keyword, include everything from keyword start to cursor
      start = keywordStart;
      end = cursorPos;
      
      // Make sure we don't go past a newline
      int checkPos = start;
      while (checkPos < end && checkPos < text.length) {
        if (text[checkPos] == '\n') {
          end = checkPos;
          break;
        }
        checkPos++;
      }
    } else {
      // Normal word detection
      while (start > 0 && !_isWordBoundaryForAutocomplete(text[start - 1])) {
        start--;
      }
      while (end < text.length && !_isWordBoundaryForAutocomplete(text[end])) {
        end++;
      }
    }
    
    String word = text.substring(start, end);
    _log('DEBUG: Final word: "$word", length: ${word.length}');
    _log('DEBUG: Text before cursor: "${text.substring(0, cursorPos)}"');
    _log('DEBUG: Start: $start, End: $end, Cursor: $cursorPos');
    
    if (word.length >= 2) {
      _log('DEBUG: Calling _getAutocompleteSuggestions with: "$word"');
      final List<String> suggestions = _getAutocompleteSuggestions(word);
      _log('DEBUG: Got ${suggestions.length} suggestions');
      if (mounted) {
        setState(() {
          _currentWord = word;
          _currentSuggestions = suggestions;
          _selectedSuggestionIndex = -1; // Reset selection when text changes
        });
      }
      // Delay overlay creation to avoid assertion failures during rebuilds
      _overlayTimer?.cancel();
      _overlayTimer = Timer(const Duration(milliseconds: 100), () {
        if (mounted && !_isRebuilding && !_isLayoutInProgress) {
          // Use SchedulerBinding to ensure we're in the right phase
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isRebuilding && !_isLayoutInProgress) {
              _showSuggestionOverlay(suggestions, word);
            }
          });
        }
      });
    } else {
      _hideSuggestionOverlay();
      if (mounted) {
        setState(() {
          _currentWord = null;
          _currentSuggestions = [];
          _selectedSuggestionIndex = -1;
        });
      }
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _devices.clear();
      _selected = null;
    });
    _log('Starting discovery…');
    await Future.wait(<Future<void>>[
      _scanSerialPorts(),
      _scanMdnsBroadcasts(),
    ]);
    setState(() {
      _isScanning = false;
    });
    _log('Discovery complete. Found ${_devices.length} device(s).');
  }

  Future<void> _scanSerialPorts() async {
    final List<String> ports = SerialPort.availablePorts.toList(growable: false);
    _log('Serial: ${ports.length} port(s) detected.');
    for (final String portName in ports) {
      final SerialPort port = SerialPort(portName);
      try {
        if (!port.openReadWrite()) {
          _log('Serial: cannot open $portName');
          continue;
        }

        SerialPortConfig config = port.config; 
        config.baudRate = 115200;
        port.config = config;

        final List<int> message = utf8.encode('Who are you?\n');
        port.write(Uint8List.fromList(message));
        _log('Serial: sent probe to $portName');

        final Stopwatch sw = Stopwatch()..start();
        final List<int> buffer = <int>[];
        while (sw.elapsedMilliseconds < 2000) {
          // Small delay to avoid busy wait
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final int available = port.bytesAvailable;
          if (available > 0) {
            final Uint8List readData = port.read(available);
            buffer.addAll(readData);
            final String data = _safeAscii(String.fromCharCodes(buffer));
            final String trimmed = data.trim();
            if (_isValidEnglish(trimmed) && trimmed.startsWith('moduleBox:')) {
              final String name = trimmed.substring('moduleBox:'.length).trim();
              final String display = name.isEmpty ? '(unnamed)' : name;
              _addOrUpdateDevice(DeviceItem(
                displayName: '$display',
                kind: 'serial',
                identifier: portName,
                extra: <String, Object?>{
                  'raw': trimmed,
                  'port': portName,
                  'baud': 115200,
                },
              ));
              _log('Serial: device "$display" on $portName');
              break;
            }
          }
        }
        if (buffer.isEmpty) {
          _log('Serial: timeout waiting response on $portName');
        }
      } catch (e) {
        _log('Serial: error on $portName: $e');
      } finally {
        try {
          if (port.isOpen) port.close();
        } catch (_) {}
        port.dispose();
      }
    }
    _log('Serial: scan finished.');
  }

  /// Parse device name from strings like "FTP server on moduleBox 'my device'"
  String? _parseDeviceNameFromString(String text) {
    // Look for pattern: "FTP server on moduleBox 'device name'"
    final RegExp pattern = RegExp(r"FTP server on moduleBox\s+'([^']+)'", caseSensitive: false);
    final Match? match = pattern.firstMatch(text);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }
    return null;
  }

  Future<void> _scanMdnsBroadcasts() async {
    try {
      _log('mDNS: Starting discovery...');
      
      //final MDnsClient client = MDnsClient();

      final MDnsClient client = MDnsClient(rawDatagramSocketFactory:
      (dynamic host, int port,
        {bool? reuseAddress, bool? reusePort, int? ttl}) {
      return RawDatagramSocket.bind(host, port,
          reuseAddress: true, reusePort: Platform.isWindows ? false : true, ttl: ttl!);
      });  

      await client.start();
      
      final List<DeviceItem> found = <DeviceItem>[];
      final Set<String> uniqueDeviceIds = <String>{}; // Track unique device identifiers
      
      try {
        // Discover FTP services (common service type for FTP servers)
        // Also try _modulebox._tcp in case it's a custom service type
//        final List<String> serviceTypes = ['_ftp._tcp', '_modulebox._tcp', '_http._tcp'];
        final List<String> serviceTypes = ['_ftp._tcp'];
        
        for (final String serviceType in serviceTypes) {
          _log('mDNS: Discovering $serviceType services...');
          
          // Query for the specific service type
          await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(serviceType),
          )) {
            final String serviceName = ptr.domainName;
            _log('mDNS: Found service: $serviceName');
            
            // Get SRV record for the service to get host and port
            await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(serviceName),
            )) {
              final String host = srv.target;
              final int port = srv.port;
              final String deviceId = '$host:$port';
              
              if (uniqueDeviceIds.contains(deviceId)) {
                continue;
              }
              
              // Get TXT record for additional information (may contain device name)
              String? deviceName;
              try {
                await for (final TxtResourceRecord txt in client.lookup<TxtResourceRecord>(
                  ResourceRecordQuery.text(serviceName),
                )) {
                  // TxtResourceRecord.text can be String or List<String>
                  String txtData;
                  if (txt.text is List) {
                    txtData = (txt.text as List).join(' ');
                  } else {
                    txtData = txt.text.toString();
                  }
                  _log('mDNS: TXT record for $serviceName: $txtData');
                  
                  // Try to parse device name from TXT record
                  final String? parsedName = _parseDeviceNameFromString(txtData);
                  if (parsedName != null) {
                    deviceName = parsedName;
                    break;
                  }
                }
              } catch (e) {
                _log('mDNS: Error reading TXT record for $serviceName: $e');
              }
              
              // If no device name found in TXT, try to extract from service name
              if (deviceName == null || deviceName.isEmpty) {
                // Try to parse from service name itself
                final String? parsedName = _parseDeviceNameFromString(serviceName);
                if (parsedName != null) {
                  deviceName = parsedName;
                } else {
                  // Use service name as fallback (remove service type suffix)
                  deviceName = serviceName.replaceAll('.$serviceType.local', '').replaceAll('.$serviceType', '');
                }
              }
              
              // Resolve hostname to IP address
              String? ipAddress;
              try {
                final List<InternetAddress> addresses = await InternetAddress.lookup(host);
                if (addresses.isNotEmpty) {
                  ipAddress = addresses.first.address;
                }
              } catch (e) {
                _log('mDNS: Error resolving hostname $host: $e');
                // Try to use host as IP if it's already an IP address
                if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) {
                  ipAddress = host;
                }
              }
              
              if (ipAddress == null) {
                _log('mDNS: Could not resolve IP for $host, skipping');
                continue;
              }
              
              uniqueDeviceIds.add(deviceId);
              found.add(DeviceItem(
                displayName: deviceName.isEmpty ? '(unnamed)' : deviceName,
                kind: 'mDNS',
                identifier: '$ipAddress:$port',
                extra: <String, Object?>{
                  'hostname': host,
                  'ip': ipAddress,
                  'port': port,
                  'service_name': serviceName,
                  'service_type': serviceType,
                },
              ));
              _log('mDNS: device "${deviceName.isEmpty ? '(unnamed)' : deviceName}" from $ipAddress:$port (hostname: $host)');
            }
          }
        }
        
        // Wait a bit for all responses
        await Future<void>.delayed(const Duration(seconds: 2));
        
      } finally {
        client.stop();
      }
      
      // Add found devices
      for (final DeviceItem d in found) {
        _addOrUpdateDevice(d);
      }
      
      _log('mDNS: scan finished. Found ${found.length} device(s).');
    } catch (e) {
      _log('mDNS: error: $e');
    }
  }

  void _addOrUpdateDevice(DeviceItem device) {
    final int existing = _devices.indexWhere((DeviceItem d) => d.identifier == device.identifier && d.kind == device.kind);
    setState(() {
      if (existing >= 0) {
        _devices[existing] = device;
      } else {
        _devices.add(device);
      }
      _devices.sort((DeviceItem a, DeviceItem b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      _selected ??= _devices.isNotEmpty ? _devices.first : null;
    });
  }

  static bool _isValidEnglish(String s) {
    // Allow letters, digits, spaces, punctuation common in names; but ensure letters present
    final RegExp allowed = RegExp(r'^[A-Za-z0-9 _:\-\.\(\)]+$');
    return s.isNotEmpty && allowed.hasMatch(s);
  }

  static String _safeAscii(String s) {
    // Replace non-printable with spaces
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final int code = s.codeUnitAt(i);
      if (code >= 32 && code <= 126) {
        b.writeCharCode(code);
      } else if (code == 10 || code == 13 || code == 9) {
        b.writeCharCode(code);
      } else {
        b.write(' ');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discovery'),
        actions: <Widget>[
          IconButton(
            onPressed: _isScanning ? null : _startScan,
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan',
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              Expanded(
                child: Row(
              children: <Widget>[
                SizedBox(
                  width: 320,
                  child: Column(
                    children: <Widget>[
                      Container(
                        height: 48,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _isScanning ? 'Scanning…' : 'Devices',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _devices.length,
                          itemBuilder: (BuildContext context, int index) {
                            final DeviceItem item = _devices[index];
                            final bool selected = identical(_selected, item);
                            return ListTile(
                              title: Text(item.displayName),
                              subtitle: Text('${item.kind} • ${item.identifier}'),
                              selected: selected,
                              onTap: () {
                                setState(() {
                                  _selected = item;
                                });
                                 // Load files based on device type
                                if (item.kind == 'serial') {
                                  _loadDeviceFiles();
                                 } else if (item.kind == 'mDNS') {
                                   _loadDeviceFilesFromFtp(item);
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _buildDetailsView(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 180,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('Logs', style: Theme.of(context).textTheme.titleSmall),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_outlined),
                        tooltip: 'Clear logs',
                        onPressed: () => setState(() => _logs.clear()),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    child: Scrollbar(
                      controller: _logsScrollController,
                      child: ListView.builder(
                        controller: _logsScrollController,
                        reverse: true,
                        itemCount: _logs.length,
                        itemBuilder: (BuildContext context, int index) {
                          final String line = _logs[_logs.length - 1 - index];
                          return Text(line, style: const TextStyle(fontFamily: 'monospace'));
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      // Debug view for scroll offset (hidden)
      // Positioned(
      //   top: 10,
      //   right: 10,
      //   child: Container(
      //     padding: const EdgeInsets.all(8),
      //     decoration: BoxDecoration(
      //       color: Colors.black.withOpacity(0.7),
      //       borderRadius: BorderRadius.circular(4),
      //     ),
      //     child: Column(
      //       crossAxisAlignment: CrossAxisAlignment.start,
      //       mainAxisSize: MainAxisSize.min,
      //       children: [
      //         Text(
      //           'Scroll: ${_debugScrollOffset.toStringAsFixed(1)}',
      //           style: const TextStyle(
      //             color: Colors.white,
      //             fontSize: 12,
      //             fontFamily: 'monospace',
      //           ),
      //         ),
      //         Text(
      //           'Cursor Y: ${_debugCursorY.toStringAsFixed(1)}',
      //           style: const TextStyle(
      //             color: Colors.white,
      //             fontSize: 12,
      //             fontFamily: 'monospace',
      //           ),
      //         ),
      //         Text(
      //           'Popup Y: ${_debugPopupY.toStringAsFixed(1)}',
      //           style: const TextStyle(
      //             color: Colors.white,
      //             fontSize: 12,
      //             fontFamily: 'monospace',
      //           ),
      //         ),
      //       ],
      //     ),
      //   ),
      // ),
    ]));
  }

  Widget _buildDetailsView() {
    final DeviceItem? item = _selected;
    if (item == null) {
      return const Center(child: Text('Select a device to see details'));
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(item.displayName, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('Kind: ${item.kind}'),
          Text('Identifier: ${item.identifier}'),
          const SizedBox(height: 8),
          TabBar(
            controller: _detailsTabController,
            tabs: const <Widget>[
              Tab(text: 'Config edit'),
              Tab(text: 'Config desig'),
              Tab(text: 'Console'),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              controller: _detailsTabController,
              children: <Widget>[
                _buildConfigEditTab(item),
                _buildConfigDesignTab(item),
                _buildConsoleTab(item),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigDesignTab(DeviceItem item) {
    final bool canSaveDesign = _isConfigDesignDirty && _cachedConfigPath != null;

    if (_parsedConfig.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Configuration:'),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text('No configuration loaded. Select a serial device to load config.ini'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _buildSaveButton(null),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Configuration:'),
        const SizedBox(height: 8),
        // Chapter selector and add SLOT chapter button
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _selectedChapter,
                decoration: const InputDecoration(
                  labelText: 'Chapter',
                  border: OutlineInputBorder(),
                ),
                items: _parsedConfig.keys.map((String chapter) {
                  return DropdownMenuItem<String>(
                    value: chapter,
                    child: Text(chapter),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedChapter = newValue;
                    _updateConfigControllers();
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _showAddSlotChapterDialog,
              icon: const Icon(Icons.add_box),
              tooltip: 'Add SLOT Chapter',
              style: IconButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _isSlotChapterSelected() ? _showDeleteSlotChapterDialog : null,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete SLOT Chapter',
              style: IconButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Configuration fields
        Expanded(
          child: _selectedChapter != null
              ? _buildConfigFields()
              : const Center(child: Text('Select a chapter to edit configuration')),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            _buildSaveButton(canSaveDesign ? _saveConfigToFile : null),
          ],
        ),
      ],
    );
  }


  Widget _buildConfigFields() {
    if (_selectedChapter == null || !_parsedConfig.containsKey(_selectedChapter)) {
      return const Center(child: Text('No chapter selected'));
    }

    final Map<String, String> chapterData = _parsedConfig[_selectedChapter!]!;
    
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          // Key/value pairs list
          Expanded(
            child: ListView(
              children: chapterData.entries.map((MapEntry<String, String> entry) {
                final bool isSlotKey = entry.key.startsWith('SLOT_');
                final bool isSlotChapter = _selectedChapter != null && _selectedChapter!.startsWith('SLOT_');
                final bool isModeKey = entry.key == 'mode' && isSlotChapter;
                final bool isOptionsKey = entry.key == 'options' && isSlotChapter;
                final bool isCrossLinkKey = entry.key == 'cross_link';
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 150,
                        child: Text(
                          entry.key,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: (isSlotKey || isSlotChapter) ? Colors.grey : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: isModeKey 
                          ? _buildSlotModeDropdown(_configControllers[entry.key]!)
                          : TextField(
                              controller: _configControllers[entry.key],
                              decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                      ),
                      const SizedBox(width: 8),
                      if (isOptionsKey)
                        IconButton(
                          onPressed: _showAddOptionDialog,
                          icon: const Icon(Icons.add),
                          tooltip: 'Add option',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        )
                      else if (isCrossLinkKey)
                        IconButton(
                          onPressed: _showAddCrossLinkRuleDialog,
                          icon: const Icon(Icons.add),
                          tooltip: 'Add rule',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                        )
                      else if (!(isSlotKey || isSlotChapter))
                        IconButton(
                          onPressed: () => _deleteKeyValue(entry.key),
                          icon: const Icon(Icons.delete),
                          color: Colors.red,
                          tooltip: 'Delete key',
                        ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
          // Add new key button at bottom
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _canAddNewKey() ? _showAddKeyDialog : null,
                  icon: const Icon(Icons.add),
                  label: Text(_canAddNewKey() ? 'Add Key/Value' : 'All keys added'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConfigEditTab(DeviceItem item) {
    if (_cachedConfigContent == null || _cachedConfigContent!.isEmpty) {
      return const Center(
        child: Text('No configuration loaded. Select a serial device to load config.ini'),
      );
    }

    final bool canSaveEditor = _isConfigEditorDirty && _cachedConfigPath != null;

    return Column(
      children: <Widget>[
        // Save button at the top
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            _buildSaveButton(canSaveEditor ? _saveConfigFromEditor : null),
          ],
        ),
        const SizedBox(height: 8),
        // Rich text editor with VSCode-style autocomplete
        Expanded(
          child: _buildRichTextEditor(),
        ),
      ],
    );
  }

  /// Build rich text editor with modal autocomplete
  Widget _buildRichTextEditor() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Main editor
          Expanded(
            child: Focus(
              onKeyEvent: _handleKeyEvent,
              child: Container(
                constraints: const BoxConstraints(),
                child: SingleChildScrollView(
                  controller: _textEditorScrollController,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 200, // Minimum height to prevent infinite constraints
                    ),
                    child: TextField(
                      focusNode: _configEditorFocusNode,
                      controller: _configEditorController,
                      maxLines: null,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(12),
                        hintText: 'Edit configuration content...',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Status bar with autocomplete info
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              border: Border(top: BorderSide(color: Colors.blue[200]!)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 12, color: Colors.blue[600]),
                const SizedBox(width: 4),
                Text(
                  _currentSuggestions.isNotEmpty
                    ? '${_currentSuggestions.length} suggestion(s) for "$_currentWord"'
                    : 'Start editing to see what happens',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.blue[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Get autocomplete suggestions (same data sources as Config design tab)
  List<String> _getAutocompleteSuggestions(String currentWord) {
    if (currentWord.isEmpty) return [];
    
    _log('DEBUG: _getAutocompleteSuggestions called with: "$currentWord"');
    // Normalize the word to handle spaces around "=" (e.g., "mode = " becomes "mode=")
    final String normalizedWord = _normalizeWordForComparison(currentWord);
    final String lowerWord = normalizedWord.toLowerCase();
    _log('DEBUG: After normalization: "$normalizedWord" -> "$lowerWord"');
    final Set<String> suggestions = <String>{};
    
    // Special handling for mode= parameter - get mode values from manifest
    if (lowerWord.startsWith('mode=') || lowerWord == 'mode') {
      _log('DEBUG: Mode condition matched! lowerWord: "$lowerWord"');
      final List<String> modeSuggestions = _getModeSuggestionsFromManifest();
      String filterText = '';
      
      if (lowerWord.startsWith('mode=')) {
        filterText = lowerWord.substring(5); // Remove 'mode=' prefix
      }
      
      for (final String mode in modeSuggestions) {
        if (filterText.isEmpty || mode.toLowerCase().contains(filterText)) {
          final String fullSuggestion = 'mode=$mode';
          // Don't suggest if it exactly matches what's already typed
          if (fullSuggestion.toLowerCase() != lowerWord) {
            suggestions.add(fullSuggestion);
          }
        }
      }
    }
    // Special handling for cross_link= parameter - step by step rule construction
    else if (lowerWord.startsWith('cross_link=') || lowerWord == 'cross_link') {
      _log('DEBUG: Cross_link= logic triggered for: $lowerWord');
      
      if (lowerWord.startsWith('cross_link=')) {
        final String crossLinkValue = lowerWord.substring(11); // Remove 'cross_link=' prefix
        
        // Handle comma-separated rules - find the last comma to get the current partial rule
        final int lastCommaIndex = crossLinkValue.lastIndexOf(',');
        String currentRule = crossLinkValue;
        String existingRules = '';
        
        if (lastCommaIndex >= 0) {
          existingRules = crossLinkValue.substring(0, lastCommaIndex + 1); // Include the comma
          currentRule = crossLinkValue.substring(lastCommaIndex + 1).trim();
          _log('DEBUG: Found comma, existing rules: "$existingRules", current rule: "$currentRule"');
        }
        
        // Get suggestions for the current rule
        final List<String> crossLinkSuggestions = _getCrossLinkStepByStepSuggestions('cross_link=$currentRule');
        _log('DEBUG: Got ${crossLinkSuggestions.length} cross_link suggestions for current rule');
        
        for (final String suggestion in crossLinkSuggestions) {
          suggestions.add(suggestion);
          _log('DEBUG: Added cross_link suggestion: "$suggestion"');
        }
      } else {
        // No cross_link= prefix, show source slots
        final List<String> sourceSlots = _getTopicBasedSourceSlots();
        for (final String slot in sourceSlots) {
          suggestions.add(slot);
        }
      }
    }
    // Special handling for options= parameter - get option values from manifest based on current mode
    else if (lowerWord.startsWith('options=') || lowerWord == 'options') {
      _log('DEBUG: Options= logic triggered for: $lowerWord');
      
      // Cache current mode for efficient description lookups during overlay rebuilds
      String? currentChapter = _getCurrentChapterFromTextEditor();
      if (currentChapter != null) {
        _cachedCurrentMode = _getModeFromTextEditor(currentChapter);
        if (_cachedCurrentMode == null || _cachedCurrentMode!.isEmpty) {
          _cachedCurrentMode = _parsedConfig[currentChapter]?['mode'];
        }
      } else if (_selectedChapter != null) {
        _cachedCurrentMode = _getModeFromTextEditor(_selectedChapter!);
        if (_cachedCurrentMode == null || _cachedCurrentMode!.isEmpty) {
          _cachedCurrentMode = _parsedConfig[_selectedChapter!]?['mode'];
        }
      }
      
      final List<String> optionSuggestions = _getOptionSuggestionsFromManifest();
      _log('DEBUG: Got ${optionSuggestions.length} option suggestions');
      String filterText = '';
      String existingOptions = '';
      
      if (lowerWord.startsWith('options=')) {
        final String optionsValue = lowerWord.substring(8); // Remove 'options=' prefix
        
        // Handle comma-separated values - find the last comma to get the current partial value
        final int lastCommaIndex = optionsValue.lastIndexOf(',');
        if (lastCommaIndex >= 0) {
          existingOptions = optionsValue.substring(0, lastCommaIndex + 1); // Include the comma
          filterText = optionsValue.substring(lastCommaIndex + 1).trim();
        } else {
          filterText = optionsValue.trim();
        }
      }
      
      for (final String option in optionSuggestions) {
        if (filterText.isEmpty || option.toLowerCase().contains(filterText.toLowerCase())) {
          // Check if this option is already present in the existing options
          bool isAlreadyPresent = false;
          if (existingOptions.isNotEmpty) {
            // Parse existing options to check for duplicates
            final String existingOptionsValue = lowerWord.substring(8); // Remove 'options=' prefix
            final List<String> existingOptionsList = existingOptionsValue.split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            
            // Check if the option (without value) is already present
            final String optionName = option.split(':').first;
            isAlreadyPresent = existingOptionsList.any((existing) => 
                existing.split(':').first.toLowerCase() == optionName.toLowerCase());
          }
          
          // Only suggest if not already present
          if (!isAlreadyPresent) {
            // For options, we want to show only the option part in the display
            // but handle the full replacement correctly
            String suggestion;
            
            if (existingOptions.isNotEmpty) {
              // Show only the new option part, but store the full replacement
              suggestion = option;
            } else {
              // Show only the option part
              suggestion = option;
            }
            
            // Don't suggest if it exactly matches what's already typed
            if (suggestion.toLowerCase() != filterText.toLowerCase()) {
              suggestions.add(suggestion);
              _log('DEBUG: Added options suggestion: $suggestion');
            }
          } else {
            _log('DEBUG: Skipped already present option: $option');
          }
        }
      }
    } else {
      // Use cached suggestions for faster filtering
      if (_cachedSuggestions.isEmpty) {
        _buildCachedSuggestions();
      }
      
      // Fast filtering of cached suggestions (already unique)
      for (final String suggestion in _cachedSuggestions) {
        if (suggestion.toLowerCase().contains(lowerWord)) {
          // Don't suggest if it exactly matches what's already typed
          if (suggestion.toLowerCase() != lowerWord) {
            suggestions.add(suggestion);
            if (suggestions.length >= 8) break; // Limit to 8 for display
          }
        }
      }
    }
    
    return suggestions.toList();
  }

  /// Build cached suggestions once for faster filtering (ensuring uniqueness)
  void _buildCachedSuggestions() {
    final Set<String> uniqueSuggestions = <String>{};
    
    // Get existing chapters from both parsed config and text editor
    final Set<String> existingChapters = <String>{};
    existingChapters.addAll(_parsedConfig.keys);
    
    // Also check text editor content for chapters that might not be parsed yet
    final String text = _configEditorController.text;
    final List<String> lines = text.split('\n');
    for (final String line in lines) {
      final String trimmedLine = line.trim();
      if (trimmedLine.startsWith('[') && trimmedLine.endsWith(']') && trimmedLine.length > 2) {
        final String chapter = trimmedLine.substring(1, trimmedLine.length - 1);
        existingChapters.add(chapter);
      }
    }
    
    // Add SLOT chapter suggestions (numbers 0-9, excluding existing ones)
    for (int i = 0; i <= 9; i++) {
      final String slotChapter = 'SLOT_$i';
      if (!existingChapters.contains(slotChapter)) {
        uniqueSuggestions.add('[$slotChapter]');
      }
    }
    
    // Add other chapter names from manifest (excluding existing ones)
    for (final String manifestChapter in _availableKeys.keys) {
      // Skip wildcard patterns and SLOT chapters (handled above)
      if (!manifestChapter.contains('*') && !manifestChapter.startsWith('SLOT_')) {
        if (!existingChapters.contains(manifestChapter)) {
          uniqueSuggestions.add('[$manifestChapter]');
        }
      }
    }
    
    // Add key names from all chapters (same as Config design)
    for (final String chapter in _parsedConfig.keys) {
      for (final String key in _parsedConfig[chapter]!.keys) {
        uniqueSuggestions.add('$key=');
      }
    }
    
    // Add topic-based slot names (same as Config design)
    try {
      final List<String> topicSlots = _getTopicBasedSourceSlots();
      uniqueSuggestions.addAll(topicSlots);
    } catch (e) {
      // Silent error handling
    }
    
    // Add manifest values for topics (same as Config design)
    if (_manifestData.isNotEmpty) {
      try {
        if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
          final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
          
          for (final dynamic modeItem in modesArray) {
            if (modeItem is Map<String, dynamic> && modeItem['options'] is List) {
              final List<dynamic> modeOptions = modeItem['options'] as List<dynamic>;
              
              for (final dynamic option in modeOptions) {
                if (option is Map<String, dynamic>) {
                  final String? name = option['name']?.toString();
                  final String? valueDefault = option['valueDefault']?.toString();
                  
                  if (name != null && name.toLowerCase().contains('topic') && valueDefault != null && valueDefault != 'null') {
                    final String cleanValue = valueDefault
                        .replaceAll(RegExp(r'^/+'), '')
                        .replaceAll(RegExp(r'[^\w\-]'), '_')
                        .replaceAll(RegExp(r'^_+'), '')
                        .replaceAll(RegExp(r'_+$'), '')
                        .replaceAll(RegExp(r'_+'), '_');
                    
                    uniqueSuggestions.add(cleanValue);
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        // Silent error handling
      }
    }
    
    // Add common config patterns
    uniqueSuggestions.addAll([
      'mode=',
      'options=',
      'cross_link=',
      'SLOT_',
      'trigger',
      'data',
      'sync',
      'true',
      'false',
      'on',
      'off',
    ]);
    
    // Convert Set to List to maintain order and ensure uniqueness
    _cachedSuggestions = uniqueSuggestions.toList();
  }

  /// Show modal suggestion overlay
  void _showSuggestionOverlay(List<String> suggestions, String currentWord) {
    _hideSuggestionOverlay(); // Remove any existing overlay
    
    if (suggestions.isEmpty) return;
    
    // Safety check to prevent assertion failures
    if (!mounted || _isRebuilding || _isLayoutInProgress) return;
    
    final Size screenSize = MediaQuery.of(context).size;
    
    // Calculate actual popup dimensions
    final double popupWidth = 300.0;
    final double popupHeight = (suggestions.length * 40.0).clamp(80.0, 300.0);
    
    // Get the real actual cursor coordinates using TextPainter and getOffsetForCaret (based on Stack Overflow solution)
    // Safety check to prevent assertion failures during widget rebuilds
    if (!_configEditorFocusNode.hasFocus || _configEditorFocusNode.context == null) {
      // Fallback to center if focus is not available
      final double popupX = (screenSize.width - popupWidth) / 2;
      final double popupY = (screenSize.height - popupHeight) / 2;
      _suggestionOverlay = OverlayEntry(
        builder: (context) => _buildSuggestionOverlayContent(suggestions, currentWord, popupX, popupY, popupWidth, popupHeight),
      );
      Overlay.of(context).insert(_suggestionOverlay!);
      return;
    }
    
    final RenderBox? focusBox = _configEditorFocusNode.context?.findRenderObject() as RenderBox?;
    if (focusBox == null) {
      // Fallback to center if we can't get the focus position
      final double popupX = (screenSize.width - popupWidth) / 2;
      final double popupY = (screenSize.height - popupHeight) / 2;
      _suggestionOverlay = OverlayEntry(
        builder: (context) => _buildSuggestionOverlayContent(suggestions, currentWord, popupX, popupY, popupWidth, popupHeight),
      );
      Overlay.of(context).insert(_suggestionOverlay!);
      return;
    }
    
    // Get the real actual position of the focused text editor
    final Offset focusPosition = focusBox.localToGlobal(Offset.zero);
    
    // Get the real actual cursor position from the text editor
    final int cursorPos = _configEditorController.selection.baseOffset;
    final String text = _configEditorController.text;
    
    // Use TextPainter to get the real actual cursor coordinates (Stack Overflow method)
    final TextPainter textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    
    textPainter.layout();
    
    // Get the real actual cursor position using getOffsetForCaret
    final Offset cursorOffset = textPainter.getOffsetForCaret(
      TextPosition(offset: cursorPos),
      Rect.zero,
    );
    
    // Calculate the real actual cursor position in screen coordinates
    // Account for content padding
    final double contentPadding = 12.0; // From InputDecoration contentPadding
    final double cursorX = focusPosition.dx + contentPadding + cursorOffset.dx;
    final double cursorY = focusPosition.dy + contentPadding + cursorOffset.dy;
    
    // Position popup above the cursor to avoid overlapping the text
    double popupX = cursorX;
    double popupY = cursorY - popupHeight - 15.0; // Position above cursor with 15px gap
    
    // If not enough space above, position below the cursor
    if (popupY < 0) {
      popupY = cursorY + 20.0; // Position below cursor with 20px gap
    }
    
    // Ensure popup doesn't go off the right edge
    if (popupX + popupWidth > screenSize.width - 20.0) {
      popupX = screenSize.width - popupWidth - 20.0;
    }
    
    // Ensure popup doesn't go off the left edge
    if (popupX < 20.0) {
      popupX = 20.0;
    }
    
    // Ensure popup doesn't go off the bottom edge
    if (popupY + popupHeight > screenSize.height - 50.0) {
      popupY = screenSize.height - popupHeight - 50.0;
    }
    
    _suggestionOverlay = OverlayEntry(
      builder: (context) => _buildSuggestionOverlayContent(suggestions, currentWord, popupX, popupY, popupWidth, popupHeight),
    );
    
    Overlay.of(context).insert(_suggestionOverlay!);
  }

  /// Build suggestion overlay content with keyboard navigation support
  Widget _buildSuggestionOverlayContent(List<String> suggestions, String currentWord, double popupX, double popupY, double popupWidth, double popupHeight) {
    return Positioned(
      left: popupX,
      top: popupY,
      child: Material(
        elevation: 8.0,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: popupWidth,
          height: popupHeight,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blue[300]!, width: 1),
          ),
          child: Column(
            children: [
              // Suggestions list
              Expanded(
                child: ListView.builder(
                  controller: _suggestionScrollController,
                  padding: EdgeInsets.zero,
                  itemCount: suggestions.length,
                  itemBuilder: (context, index) {
                    final String suggestion = suggestions[index];
                    final bool isSelected = index == _selectedSuggestionIndex;
                    
                    return Container(
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blue[100] : null,
                        border: index < suggestions.length - 1
                          ? Border(bottom: BorderSide(color: Colors.grey[200]!))
                          : null,
                      ),
                      child: ListTile(
                        dense: true,
                        leading: _getSuggestionIcon(suggestion),
                        title: Text(
                          suggestion,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          _getSuggestionContext(suggestion),
                          style: TextStyle(
                            fontSize: 10,
                            color: isSelected ? Colors.blue[700] : Colors.grey[600],
                          ),
                        ),
                        onTap: () => _selectSuggestion(suggestion, currentWord, fromMouseClick: true),
                        hoverColor: Colors.blue[50],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Update suggestion overlay to reflect current selection
  void _updateSuggestionOverlay() {
    if (!mounted || _isRebuilding || _isLayoutInProgress) return;
    
    if (_suggestionOverlay != null && _currentSuggestions.isNotEmpty && _currentWord != null) {
      _suggestionOverlay!.markNeedsBuild();
      _scrollToSelectedSuggestion();
    }
  }

  /// Scroll to center the currently selected suggestion
  void _scrollToSelectedSuggestion() {
    if (_selectedSuggestionIndex >= 0 && _currentSuggestions.isNotEmpty) {
      final double itemHeight = 40.0; // Height of each suggestion item
      final double targetOffset = _selectedSuggestionIndex * itemHeight;
      final double maxScrollExtent = _suggestionScrollController.position.maxScrollExtent;
      final double viewportHeight = _suggestionScrollController.position.viewportDimension;
      
      double scrollOffset;
      
      // Calculate how many items can fit in the viewport
      final double itemsInViewport = viewportHeight / itemHeight;
      final double itemsFromEnd = _currentSuggestions.length - _selectedSuggestionIndex - 1;
      
      if (_selectedSuggestionIndex < itemsInViewport / 2) {
        // Item is near the beginning - scroll to top with some padding
        scrollOffset = 0.0;
      } else if (itemsFromEnd < itemsInViewport / 2) {
        // Item is near the end - scroll to bottom with some padding
        scrollOffset = maxScrollExtent;
      } else {
        // Item is in the middle - center it
        scrollOffset = targetOffset - (viewportHeight / 2) + (itemHeight / 2);
      }
      
      // Clamp the offset to valid range
      final double clampedOffset = scrollOffset.clamp(0.0, maxScrollExtent);
      
      _suggestionScrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  /// Hide suggestion overlay
  void _hideSuggestionOverlay() {
    if (_suggestionOverlay != null) {
      _suggestionOverlay!.remove();
      _suggestionOverlay = null;
    }
    _selectedSuggestionIndex = -1;
  }

  /// Select a suggestion and insert it into the text
  /// [fromMouseClick] if true, indicates the suggestion was selected via mouse click
  void _selectSuggestion(String suggestion, String currentWord, {bool fromMouseClick = false}) {
    final String text = _configEditorController.text;
    final int cursorPos = _configEditorController.selection.baseOffset;
    
    if (cursorPos <= 0) return;
    
    // Find current word boundaries using the same logic as autocomplete detection
    // Use the same improved keyword detection logic to handle "mode =", "mode=", etc.
    int start = cursorPos;
    int end = cursorPos;
    
    // First, try to find if we're in a known keyword context by looking backwards from cursor
    int keywordStart = cursorPos;
    int lookBack = cursorPos;
    
    // Look backwards to find a known keyword (mode, options, cross_link)
    final int maxLookback = 200;
    while (lookBack > 0 && lookBack > cursorPos - maxLookback) {
      final char = text[lookBack - 1];
      if (char == '\n') break;
      
      final testWord = text.substring(lookBack - 1, cursorPos);
      final normalizedTest = _normalizeWordForComparison(testWord).toLowerCase();
      
      String? matchedKeyword;
      if (normalizedTest == 'mode' || normalizedTest.startsWith('mode=')) {
        matchedKeyword = 'mode';
      } else if (normalizedTest == 'options' || normalizedTest.startsWith('options=')) {
        matchedKeyword = 'options';
      } else if (normalizedTest == 'cross_link' || normalizedTest.startsWith('cross_link=')) {
        matchedKeyword = 'cross_link';
      }
      
      if (matchedKeyword != null) {
        // Found a keyword match, now find the actual start of the keyword
        int actualKeywordStart = lookBack - 1;
        
        // Look backwards to find the start of the keyword word
        for (int i = actualKeywordStart; i >= 0 && i > actualKeywordStart - 100; i--) {
          if (i < text.length) {
            final String checkText = text.substring(i, cursorPos);
            final String normalizedCheck = _normalizeWordForComparison(checkText).toLowerCase();
            
            if (normalizedCheck.startsWith(matchedKeyword)) {
              if (i == 0 || _isWordBoundaryForAutocomplete(text[i - 1])) {
                final String keywordFirstChar = matchedKeyword[0];
                if (i < text.length && text[i].toLowerCase() == keywordFirstChar) {
                  actualKeywordStart = i;
                  break;
                }
              }
            }
          }
        }
        
        keywordStart = actualKeywordStart;
        break;
      }
      
      lookBack--;
    }
    
    // If we found a keyword, use it; otherwise use normal word detection
    if (keywordStart < cursorPos) {
      start = keywordStart;
      end = cursorPos;
      
      // Make sure we don't go past a newline
      int checkPos = start;
      while (checkPos < end && checkPos < text.length) {
        if (text[checkPos] == '\n') {
          end = checkPos;
          break;
        }
        checkPos++;
      }
    } else {
      // Normal word detection
      while (start > 0 && !_isWordBoundaryForAutocomplete(text[start - 1])) {
        start--;
      }
      while (end < text.length && !_isWordBoundaryForAutocomplete(text[end])) {
        end++;
      }
    }
    
    _log('DEBUG: Replacing text from $start to $end (current word: "$currentWord") with "$suggestion"');
    
    // Normalize current word to handle spaces around "="
    final String normalizedCurrentWord = _normalizeWordForComparison(currentWord);
    
    // Special handling for different suggestion types
    String replacementText = suggestion;
    int replacementStart = start;
    int replacementEnd = end;
    
    if (suggestion.startsWith('mode=') && (normalizedCurrentWord.startsWith('mode=') || normalizedCurrentWord == 'mode')) {
      // For mode= suggestions, only replace the value part after "mode=" (or "mode =")
      final String modeValue = suggestion.substring(5); // Remove "mode=" prefix
      
      // Find the actual "=" position in the original text (accounting for spaces)
      int equalsPos = start;
      while (equalsPos < end && equalsPos < text.length) {
        if (text[equalsPos] == '=') {
          break;
        }
        equalsPos++;
      }
      
      if (equalsPos < end && text[equalsPos] == '=') {
        // Found "=", replace everything after it (including spaces)
        replacementText = modeValue;
        replacementStart = equalsPos + 1;
        // Skip any spaces after "="
        while (replacementStart < end && replacementStart < text.length && 
               text[replacementStart] == ' ') {
          replacementStart++;
        }
        replacementEnd = end;
      } else {
        // No "=" found, replace the entire word
        replacementText = suggestion;
      }
    } else if (normalizedCurrentWord.startsWith('options=') || normalizedCurrentWord == 'options') {
      // For options= suggestions, the suggestion is just the option part
      // We need to handle comma-separated values correctly
      // Find the actual "=" position in the original text (accounting for spaces)
      int equalsPos = start;
      while (equalsPos < end && equalsPos < text.length) {
        if (text[equalsPos] == '=') {
          break;
        }
        equalsPos++;
      }
      
      if (equalsPos < end && text[equalsPos] == '=') {
        // Found "=", get the value part after it
        int valueStart = equalsPos + 1;
        // Skip any spaces after "="
        while (valueStart < end && valueStart < text.length && text[valueStart] == ' ') {
          valueStart++;
        }
        
        // Extract options value from normalized word for parsing
        final int normalizedEqualsIndex = normalizedCurrentWord.indexOf('=');
        final String currentOptionsValue = normalizedEqualsIndex >= 0 && normalizedEqualsIndex < normalizedCurrentWord.length - 1
            ? normalizedCurrentWord.substring(normalizedEqualsIndex + 1)
            : '';
        
        final int lastCommaIndex = currentOptionsValue.lastIndexOf(',');
        
        // Parse existing options to check for duplicates
        final List<String> existingOptionsList = currentOptionsValue.split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        
        final String suggestionName = suggestion.split(':').first;
        final bool isAlreadyPresent = existingOptionsList.any((existing) => 
            existing.split(':').first.toLowerCase() == suggestionName.toLowerCase());
        
        if (isAlreadyPresent) {
          // Option already exists, find and replace the matching option
          int optionIndex = -1;
          for (int i = 0; i < existingOptionsList.length; i++) {
            final String option = existingOptionsList[i];
            final String optionName = option.split(':').first;
            if (optionName.toLowerCase() == suggestionName.toLowerCase()) {
              optionIndex = i;
              break;
            }
          }
          
          if (optionIndex >= 0) {
            // Calculate the start position of this option in the text
            int optionStart = valueStart;
            for (int j = 0; j < optionIndex; j++) {
              // Find the option in the original text
              int commaPos = currentOptionsValue.indexOf(',', optionStart - valueStart);
              if (commaPos >= 0) {
                optionStart = valueStart + commaPos + 1;
                // Skip spaces after comma
                while (optionStart < text.length && text[optionStart] == ' ') {
                  optionStart++;
                }
              }
            }
            
            // Find the end of this option (next comma or end)
            int optionEnd = optionStart;
            int commaInValue = currentOptionsValue.indexOf(',', optionStart - valueStart);
            if (commaInValue >= 0) {
              optionEnd = valueStart + commaInValue;
            } else {
              optionEnd = end;
            }
            
            replacementText = suggestion;
            replacementStart = optionStart;
            replacementEnd = optionEnd;
          }
        } else if (lastCommaIndex >= 0) {
          // There are existing options, add the new one after the last comma
          // Check if there's a trailing comma (comma at the end of the value)
          final bool hasTrailingComma = lastCommaIndex == currentOptionsValue.length - 1;
          
          if (hasTrailingComma) {
            // Trailing comma means we're adding a new option after existing ones
            // Replace from after the trailing comma to the end
            replacementText = suggestion;
            replacementStart = valueStart + lastCommaIndex + 1;
            // Skip any spaces after comma
            while (replacementStart < text.length && replacementStart < end && 
                   text[replacementStart] == ' ') {
              replacementStart++;
            }
            replacementEnd = end;
          } else {
            // Comma in the middle, replace the partial value after the last comma
            replacementText = suggestion;
            replacementStart = valueStart + lastCommaIndex + 1;
            // Skip any spaces after comma
            while (replacementStart < text.length && replacementStart < end && 
                   text[replacementStart] == ' ') {
              replacementStart++;
            }
            replacementEnd = end;
          }
        } else {
          // No existing options or comma
          if (currentOptionsValue.trim().isEmpty) {
            // Empty value, just add the option
            replacementText = suggestion;
            replacementStart = valueStart;
            replacementEnd = end;
          } else {
            // There's an existing value but no comma - append the new option with comma
            // We need to replace the entire value with "existingValue, newValue"
            replacementText = '$currentOptionsValue, $suggestion';
            replacementStart = valueStart;
            replacementEnd = end;
          }
        }
      } else {
        // No "=" found, replace the entire word
        replacementText = suggestion;
      }
    } else if (normalizedCurrentWord.startsWith('cross_link=') || normalizedCurrentWord == 'cross_link') {
      // For cross_link= suggestions, handle step-by-step construction with comma support
      // Find the actual "=" position in the original text (accounting for spaces)
      int equalsPos = start;
      while (equalsPos < end && equalsPos < text.length) {
        if (text[equalsPos] == '=') {
          break;
        }
        equalsPos++;
      }
      
      if (equalsPos < end && text[equalsPos] == '=') {
        // Found "=", get the value part after it
        int valueStart = equalsPos + 1;
        // Skip any spaces after "="
        while (valueStart < end && valueStart < text.length && text[valueStart] == ' ') {
          valueStart++;
        }
        
        // Extract the cross_link value from the normalized word for parsing
        final int normalizedEqualsIndex = normalizedCurrentWord.indexOf('=');
        final String currentCrossLinkValue = normalizedEqualsIndex >= 0 && normalizedEqualsIndex < normalizedCurrentWord.length - 1
            ? normalizedCurrentWord.substring(normalizedEqualsIndex + 1)
            : '';
        
        // Handle comma-separated rules - find the last comma to get the current partial rule
        final int lastCommaIndex = currentCrossLinkValue.lastIndexOf(',');
        String currentRule = currentCrossLinkValue;
        String existingRules = '';
        
        if (lastCommaIndex >= 0) {
          existingRules = currentCrossLinkValue.substring(0, lastCommaIndex + 1); // Include the comma
          currentRule = currentCrossLinkValue.substring(lastCommaIndex + 1).trim();
        }
        
        final CrossLinkStepType stepType = _parseCrossLinkStep(currentRule);
        
        if (stepType == CrossLinkStepType.sourceSlot) {
          // Step 1: Replace the current rule with the source slot
          replacementText = existingRules + suggestion;
          replacementStart = valueStart;
          replacementEnd = end;
        } else if (stepType == CrossLinkStepType.sourceReport) {
          // Step 2: Add source report after source slot with /
          final String sourceSlot = _extractSourceSlotFromCrossLink(currentRule);
          replacementText = existingRules + '$sourceSlot/$suggestion' + ':';
          replacementStart = valueStart;
          replacementEnd = end;
        } else if (stepType == CrossLinkStepType.sourceValue) {
          // Step 3: Add source value after source report with :
          final String sourcePart = currentRule.split('->')[0];
          replacementText = existingRules + '$sourcePart:$suggestion';
          replacementStart = valueStart;
          replacementEnd = end;
        } else if (stepType == CrossLinkStepType.targetSlot) {
          // Step 4: Add target slot after source part with ->
          final String sourcePart = currentRule.split('->')[0];
          replacementText = existingRules + '$sourcePart->$suggestion';
          replacementStart = valueStart;
          replacementEnd = end;
        } else if (stepType == CrossLinkStepType.targetCommand) {
          // Step 5: Add target command after target slot with /
          final String targetSlot = _extractTargetSlotFromCrossLink(currentRule);
          final String sourcePart = currentRule.split('->')[0];
          replacementText = existingRules + '$sourcePart->$targetSlot/$suggestion' + ':';
          replacementStart = valueStart;
          replacementEnd = end;
        } else if (stepType == CrossLinkStepType.targetValue) {
          // Step 6: Add target value after target command with =
          final String targetPart = currentRule.split('->')[1];
          final String sourcePart = currentRule.split('->')[0];
          replacementText = existingRules + '$sourcePart->$targetPart=$suggestion';
          replacementStart = valueStart;
          replacementEnd = end;
        }
      } else {
        // No "=" found, replace the entire word
        replacementText = suggestion;
      }
    } else if (suggestion.startsWith('[') && suggestion.endsWith(']')) {
      // For chapter suggestions, replace the entire current word with the full suggestion
      replacementText = suggestion;
      replacementStart = start;
      replacementEnd = end;
    }
    
    _log('DEBUG: Final replacement: "$replacementText" from $replacementStart to $replacementEnd');
    
    // Replace the text with the suggestion
    _configEditorController.value = _configEditorController.value.copyWith(
      text: text.substring(0, replacementStart) + replacementText + text.substring(replacementEnd),
      selection: TextSelection.collapsed(offset: replacementStart + replacementText.length),
    );
    
    _hideSuggestionOverlay();
    
    // If selected via mouse click, return focus to the text editor
    if (fromMouseClick) {
      Future.microtask(() {
        if (mounted) {
          _configEditorFocusNode.requestFocus();
        }
      });
    }
    
    // If a mode was changed, refresh suggestions to update options= suggestions for the current SLOT
    if (suggestion.startsWith('mode=') && (normalizedCurrentWord.startsWith('mode=') || normalizedCurrentWord == 'mode')) {
      // Clear cached mode since it may have changed
      _cachedCurrentMode = null;
      // Use Future.microtask to ensure the text update is complete before refreshing
      Future.microtask(() {
        _updateAutocompleteSuggestions();
      });
    }
  }

  /// Get suggestion icon
  Widget _getSuggestionIcon(String suggestion) {
    if (suggestion.startsWith('[') && suggestion.endsWith(']')) {
      return Icon(Icons.folder, size: 16, color: Colors.orange[600]);
    } else if (suggestion.startsWith('mode=')) {
      return Icon(Icons.tune, size: 16, color: Colors.indigo[600]);
    } else if (suggestion.endsWith('=')) {
      return Icon(Icons.key, size: 16, color: Colors.blue[600]);
    } else if (suggestion.startsWith('SLOT_')) {
      return Icon(Icons.settings, size: 16, color: Colors.green[600]);
    } else if (['true', 'false', 'on', 'off'].contains(suggestion)) {
      return Icon(Icons.check_circle, size: 16, color: Colors.green[600]);
    } else {
      return Icon(Icons.topic, size: 16, color: Colors.purple[600]);
    }
  }

  /// Get suggestion context description
  String _getSuggestionContext(String suggestion) {
    final String? currentWord = _currentWord;

    if (suggestion.startsWith('[') && suggestion.endsWith(']')) {
      return 'Configuration section/chapter';
    } else if (suggestion.startsWith('mode=')) {
      // Extract mode value and get description from manifest
      final String modeValue = suggestion.substring(5); // Remove "mode=" prefix
      final String? description = _getModeDescriptionFromManifest(modeValue);
      return description ?? 'Mode from manifest modes array';
    } else if (currentWord != null && (currentWord == 'cross_link' || currentWord.startsWith('cross_link='))) {
      final String crossLinkValue = currentWord == 'cross_link' ? '' : currentWord.substring(11); // Remove 'cross_link=' prefix
      final CrossLinkStepType stepType = _parseCrossLinkStep(crossLinkValue, logEnabled: false);

      if (stepType == CrossLinkStepType.sourceSlot || stepType == CrossLinkStepType.targetSlot) {
        final String? description = _getModeDescriptionForSlot(suggestion);
        if (description != null && description.isNotEmpty) {
          return description;
        }
        return 'Slot from manifest';
      } else if (stepType == CrossLinkStepType.sourceReport) {
        if (suggestion.isEmpty) {
          return 'Source report';
        }
        final String sourceSlot = _extractSourceSlotFromCrossLink(crossLinkValue);
        final String? description = _getSourceReportDescriptionFromManifest(sourceSlot, suggestion);
        if (description != null && description.isNotEmpty) {
          return description;
        }
        return 'Source report from manifest';
      } else if (stepType == CrossLinkStepType.targetCommand) {
        if (suggestion.isEmpty) {
          return 'Target command';
        }
        final String targetSlot = _extractTargetSlotFromCrossLink(crossLinkValue);
        final String? description = _getTargetCommandDescriptionFromManifest(targetSlot, suggestion);
        if (description != null && description.isNotEmpty) {
          return description;
        }
        return 'Target command from manifest';
      }
      // For other cross_link steps (e.g., values), fall through to default handling
      return 'Cross link value';
    } else if (suggestion.contains(':') && !suggestion.startsWith('SLOT_')) {
      // This might be an option suggestion (format: "name:value")
      // Only check if it's not a SLOT reference
      final String optionName = suggestion.split(':').first.trim();
      if (optionName.isNotEmpty) {
        final String? description = _getOptionDescriptionFromManifest(optionName);
        if (description != null && description.isNotEmpty) {
          return description;
        }
      }
      return 'Option from manifest';
    } else if (suggestion.endsWith('=')) {
      return 'Configuration key';
    } else if (suggestion.startsWith('SLOT_')) {
      return 'Slot reference';
    } else if (['true', 'false', 'on', 'off'].contains(suggestion)) {
      return 'Boolean value';
    } else {
      return 'Topic/Value from manifest';
    }
  }
  
  /// Normalize description text by removing unnecessary spaces, line breaks, and escape symbols
  String _normalizeDescription(String? description) {
    if (description == null || description.isEmpty) {
      return '';
    }
    
    // Remove escape symbols (\n, \r, \t, etc.) and replace with spaces
    String normalized = description
        .replaceAll(RegExp(r'\\[nrtbf]'), ' ') // Replace \n, \r, \t, \b, \f with space
        .replaceAll(RegExp(r'\\u[0-9a-fA-F]{4}'), ' ') // Replace unicode escapes with space
        .replaceAll('\n', ' ') // Replace actual newlines
        .replaceAll('\r', ' ') // Replace carriage returns
        .replaceAll('\t', ' ') // Replace tabs
        .replaceAll(RegExp(r'\s+'), ' ') // Replace multiple whitespace with single space
        .trim(); // Remove leading/trailing whitespace
    
    return normalized;
  }

  /// Get the mode value associated with a slot (handles complex slot identifiers)
  String? _getModeForSlot(String slotName) {
    if (slotName.isEmpty) {
      return null;
    }

    final String actualSlot = _extractActualSlotFromComplex(slotName);

    // Prioritize the text editor for real-time updates
    String? modeValue = _getModeFromTextEditor(actualSlot, logEnabled: false);
    if (modeValue == null || modeValue.isEmpty) {
      modeValue = _parsedConfig[actualSlot]?['mode'];
    }

    return modeValue;
  }

  /// Get the mode description for a slot by combining slot lookup with manifest data
  String? _getModeDescriptionForSlot(String slotName) {
    final String? modeValue = _getModeForSlot(slotName);
    if (modeValue == null || modeValue.isEmpty) {
      return null;
    }
    return _getModeDescriptionFromManifest(modeValue);
  }
  
  /// Get mode description from manifest
  String? _getModeDescriptionFromManifest(String modeValue) {
    try {
      if (_manifestData.isNotEmpty && _manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            if (modeName == modeValue) {
              final String? description = modeItem['description']?.toString();
              if (description != null && description.isNotEmpty) {
                return _normalizeDescription(description);
              }
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    return null;
  }
  
  /// Get option description from manifest for the current mode
  /// Uses cached mode to avoid expensive text parsing on every call
  String? _getOptionDescriptionFromManifest(String optionName) {
    try {
      // Use cached mode if available, otherwise get it fresh
      String? currentMode = _cachedCurrentMode;
      
      if (currentMode == null || currentMode.isEmpty) {
        // Cache miss - get the mode (but don't cache it here to avoid stale data)
        String? currentChapter = _getCurrentChapterFromTextEditor();
        
        if (currentChapter != null) {
          currentMode = _getModeFromTextEditor(currentChapter, logEnabled: false);
          if (currentMode == null || currentMode.isEmpty) {
            currentMode = _parsedConfig[currentChapter]?['mode'];
          }
        } else if (_selectedChapter != null) {
          currentMode = _getModeFromTextEditor(_selectedChapter!, logEnabled: false);
          if (currentMode == null || currentMode.isEmpty) {
            currentMode = _parsedConfig[_selectedChapter!]?['mode'];
          }
        }
      }
      
      if (currentMode != null && currentMode.isNotEmpty && _manifestData.isNotEmpty) {
        if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
          final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
          
          for (final dynamic modeItem in modesArray) {
            if (modeItem is Map<String, dynamic>) {
              final String? modeName = modeItem['mode']?.toString();
              if (modeName == currentMode && modeItem['options'] is List) {
                final List<dynamic> modeOptions = modeItem['options'] as List<dynamic>;
                
                for (final dynamic option in modeOptions) {
                  if (option is Map<String, dynamic>) {
                    final String? name = option['name']?.toString();
                    if (name == optionName) {
                      final String? description = option['description']?.toString();
                      if (description != null && description.isNotEmpty) {
                        return _normalizeDescription(description);
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    return null;
  }

  /// Get source report description from manifest for a given source slot and report topic
  String? _getSourceReportDescriptionFromManifest(String sourceSlot, String reportTopic) {
    try {
      if (_manifestData.isEmpty || reportTopic.isEmpty) {
        return null;
      }

      final String? modeValue = _getModeForSlot(sourceSlot);
      if (modeValue == null || modeValue.isEmpty) {
        return null;
      }

      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;

        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();

            if (modeName == modeValue && modeItem['reports'] is List) {
              final List<dynamic> reportsArray = modeItem['reports'] as List<dynamic>;

              for (final dynamic report in reportsArray) {
                if (report is Map<String, dynamic>) {
                  final String? topic = report['topic']?.toString();
                  if (topic == reportTopic || (topic != null && topic == '/$reportTopic')) {
                    final String? description = report['description']?.toString();
                    if (description != null && description.isNotEmpty) {
                      return _normalizeDescription(description);
                    }
                  }
                }
              }
              break;
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    return null;
  }

  /// Get target command description from manifest for a given target slot and command name
  String? _getTargetCommandDescriptionFromManifest(String targetSlot, String commandName) {
    try {
      if (_manifestData.isEmpty || targetSlot.isEmpty || commandName.isEmpty) {
        return null;
      }

      final String actualSlot = _extractActualSlotFromComplex(targetSlot);
      String? modeValue = _getModeFromTextEditor(actualSlot, logEnabled: false);
      if (modeValue == null || modeValue.isEmpty) {
        modeValue = _parsedConfig[actualSlot]?['mode'];
      }

      if (modeValue == null || modeValue.isEmpty) {
        return null;
      }

      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;

        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();

            if (modeName == modeValue && modeItem['commands'] is List) {
              final List<dynamic> commandsArray = modeItem['commands'] as List<dynamic>;

              for (final dynamic command in commandsArray) {
                if (command is Map<String, dynamic>) {
                  final String? cmd = command['command']?.toString();
                  if (cmd == commandName) {
                    final String? description = command['description']?.toString();
                    if (description != null && description.isNotEmpty) {
                      return _normalizeDescription(description);
                    }
                  }
                }
              }
              break;
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    return null;
  }

  /// Get mode suggestions from manifest modes array, filtered by slots field
  List<String> _getModeSuggestionsFromManifest() {
    final List<String> modeSuggestions = <String>[];
    
    try {
      // Get current slot number from context
      String? currentSlotNumber;
      String? currentChapter = _getCurrentChapterFromTextEditor();
      
      if (currentChapter != null && currentChapter.startsWith('SLOT_')) {
        currentSlotNumber = _extractSlotNumber(currentChapter);
      }
      
      if (_manifestData.isNotEmpty && _manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeValue = modeItem['mode']?.toString();
            final String? slotsField = modeItem['slots']?.toString();
            
            if (modeValue != null && modeValue.isNotEmpty) {
              // If we have a current slot number, check if this mode supports it
              if (currentSlotNumber != null && slotsField != null && slotsField.isNotEmpty) {
                if (_isSlotValidForMode(currentSlotNumber, slotsField)) {
                  modeSuggestions.add(modeValue);
                }
              } else {
                // If no current slot context or no slots field, include all modes
                modeSuggestions.add(modeValue);
              }
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    
    return modeSuggestions;
  }

  /// Check if a slot number is valid for a mode based on its slots field
  /// Supports formats like "0-5", "1", "6-9", "0,2,4", etc.
  bool _isSlotValidForMode(String slotNumber, String slotsField) {
    try {
      final int slot = int.parse(slotNumber);
      
      // Handle range format like "0-5", "6-9"
      if (slotsField.contains('-')) {
        final List<String> rangeParts = slotsField.split('-');
        if (rangeParts.length == 2) {
          final int? start = int.tryParse(rangeParts[0].trim());
          final int? end = int.tryParse(rangeParts[1].trim());
          if (start != null && end != null) {
            return slot >= start && slot <= end;
          }
        }
      }
      
      // Handle comma-separated format like "0,2,4" or single number like "1"
      final List<String> slotNumbers = slotsField.split(',');
      for (final String slotStr in slotNumbers) {
        final int? slotValue = int.tryParse(slotStr.trim());
        if (slotValue != null && slotValue == slot) {
          return true;
        }
      }
      
      return false;
    } catch (e) {
      // If parsing fails, assume the mode is valid (fallback behavior)
      return true;
    }
  }


  /// Determine the current chapter from the text editor context
  /// by looking at the text around the cursor position
  String? _getCurrentChapterFromTextEditor() {
    final String text = _configEditorController.text;
    final int cursorPos = _configEditorController.selection.baseOffset;
    
    if (cursorPos <= 0 || text.isEmpty) {
      return null;
    }
    
    // Find the most recent chapter header before the cursor position
    final List<String> lines = text.substring(0, cursorPos).split('\n');
    String? lastChapter;
    
    // Look backwards through lines to find the most recent chapter header
    for (int i = lines.length - 1; i >= 0; i--) {
      final String line = lines[i].trim();
      // Check if this line looks like a chapter header (starts with [ and ends with ])
      if (line.startsWith('[') && line.endsWith(']') && line.length > 2) {
        lastChapter = line.substring(1, line.length - 1); // Remove [ and ]
        break;
      }
    }
    
    _log('DEBUG: Detected chapter from text editor: $lastChapter');
    return lastChapter;
  }

  /// Normalize a word by removing spaces around "=" for comparison
  /// Converts "mode = " to "mode=", "mode  =  value" to "mode=value", etc.
  String _normalizeWordForComparison(String word) {
    return word.replaceAll(RegExp(r'\s*=\s*'), '=');
  }

  /// Get the mode value for a chapter directly from the text editor content
  /// Handles flexible spacing around "=" (e.g., "mode=", "mode =", "mode = ")
  String? _getModeFromTextEditor(String chapterName, {bool logEnabled = true}) {
    final String text = _configEditorController.text;
    final List<String> lines = text.split('\n');
    
    bool inChapter = false;
    for (final String line in lines) {
      final String trimmedLine = line.trim();
      
      // Check if this is the chapter header
      if (trimmedLine.startsWith('[') && trimmedLine.endsWith(']')) {
        final String chapter = trimmedLine.substring(1, trimmedLine.length - 1);
        inChapter = (chapter == chapterName);
        continue;
      }
      
      // If we're in the target chapter, look for mode= line with flexible spacing
      if (inChapter && trimmedLine.contains('=')) {
        // Parse the key=value pair with flexible spacing
        final int equalIndex = trimmedLine.indexOf('=');
        if (equalIndex > 0) {
          final String key = trimmedLine.substring(0, equalIndex).trim();
          if (key.toLowerCase() == 'mode') {
            final String mode = trimmedLine.substring(equalIndex + 1).trim();
            if (logEnabled) {
              _log('DEBUG: Found mode in text editor for $chapterName: $mode');
            }
            return mode;
          }
        }
      }
      
      // If we hit another chapter header, we're no longer in this chapter
      if (inChapter && trimmedLine.startsWith('[') && trimmedLine.endsWith(']')) {
        break;
      }
    }
    
    if (logEnabled) {
      _log('DEBUG: No mode found in text editor for $chapterName');
    }
    return null;
  }

  /// Get option suggestions from manifest based on currently selected mode
  /// Returns options in "name"="valueDefault" format
  List<String> _getOptionSuggestionsFromManifest() {
    final List<String> optionSuggestions = <String>[];
    
    try {
      // Get the currently selected chapter's mode
      String? currentMode;
      String? currentChapter;
      
      // Try to determine the chapter from the text editor context first
      currentChapter = _getCurrentChapterFromTextEditor();
      if (currentChapter != null) {
        // Prioritize getting mode from text editor (real-time editing) over parsed config
        // This ensures that when mode= is changed, options= suggestions update immediately
        currentMode = _getModeFromTextEditor(currentChapter);
        if (currentMode == null || currentMode.isEmpty) {
          // Fallback to parsed config if not found in text editor
          currentMode = _parsedConfig[currentChapter]?['mode'];
        }
        _log('DEBUG: Found chapter from text editor: $currentChapter, mode: $currentMode');
      } else {
        // Fallback to selected chapter
        if (_selectedChapter != null) {
          currentChapter = _selectedChapter;
          // Try text editor first, then fallback to parsed config
          currentMode = _getModeFromTextEditor(_selectedChapter!);
          if (currentMode == null || currentMode.isEmpty) {
            currentMode = _parsedConfig[_selectedChapter!]?['mode'];
          }
          _log('DEBUG: Using selected chapter: $currentChapter, mode: $currentMode');
        }
      }
      
      if (currentMode == null || currentMode.isEmpty) {
        return optionSuggestions;
      }
      
      if (_manifestData.isNotEmpty && _manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        
        // Find the matching mode in the manifest
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            
            if (modeName == currentMode && modeItem['options'] is List) {
              final List<dynamic> modeOptions = modeItem['options'] as List<dynamic>;
              
              for (final dynamic option in modeOptions) {
                if (option is Map<String, dynamic>) {
                  final String? name = option['name']?.toString();
                  final String? valueDefault = option['valueDefault']?.toString();
                  
                  if (name != null && name.isNotEmpty && 
                      valueDefault != null && valueDefault.isNotEmpty && valueDefault != 'null') {
                    final String option = '$name:$valueDefault';
                    optionSuggestions.add(option);
                    _log('DEBUG: Added option: $option');
                  }
                }
              }
              break; // Found the matching mode, no need to continue
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    
    return optionSuggestions;
  }

  /// Handle keyboard events for Tab navigation
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.tab && _suggestionOverlay != null && _currentSuggestions.isNotEmpty) {
        if (_selectedSuggestionIndex == -1) {
          // First Tab press - select first suggestion
          _selectedSuggestionIndex = 0;
          _updateSuggestionOverlay();
          return KeyEventResult.handled;
        }
        // Tab with suggestion selected - don't handle, let it pass through
      } else if (event.logicalKey == LogicalKeyboardKey.enter && _suggestionOverlay != null && _currentSuggestions.isNotEmpty && _selectedSuggestionIndex >= 0) {
        // Enter key - select the highlighted suggestion
        _selectSuggestion(_currentSuggestions[_selectedSuggestionIndex], _currentWord ?? '');
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.escape && _suggestionOverlay != null && _currentSuggestions.isNotEmpty) {
        // Escape - hide suggestions
        _hideSuggestionOverlay();
        _selectedSuggestionIndex = -1;
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown && _suggestionOverlay != null && _currentSuggestions.isNotEmpty) {
        // Arrow down - navigate to next suggestion
        if (_selectedSuggestionIndex == -1) {
          // First arrow key press - always select first suggestion
          _selectedSuggestionIndex = 0;
        } else if (_selectedSuggestionIndex < _currentSuggestions.length - 1) {
          _selectedSuggestionIndex++;
        }
        _updateSuggestionOverlay();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp && _suggestionOverlay != null && _currentSuggestions.isNotEmpty) {
        // Arrow up - navigate to previous suggestion
        if (_selectedSuggestionIndex == -1) {
          // First arrow key press - always select first suggestion
          _selectedSuggestionIndex = 0;
        } else if (_selectedSuggestionIndex > 0) {
          _selectedSuggestionIndex--;
        }
        _updateSuggestionOverlay();
        return KeyEventResult.handled;
      } else if (_suggestionOverlay != null &&
          _currentSuggestions.isNotEmpty &&
          (
            event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.home ||
            event.logicalKey == LogicalKeyboardKey.end ||
            event.logicalKey == LogicalKeyboardKey.pageUp ||
            event.logicalKey == LogicalKeyboardKey.pageDown
          )) {
        _hideSuggestionOverlay();
        _selectedSuggestionIndex = -1;
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Check if character is a word boundary for autocomplete (doesn't include =, [, ])
  bool _isWordBoundaryForAutocomplete(String char) {
    //return char == ' ' || char == '\n' || char == '\t' || char == ':';
    return char == ' ' || char == '\n' || char == '\t';
  }


  Future<void> _saveConfigFromEditor() async {
    await _saveConfigFromEditorWithResult();
  }

  /// Save config from editor and return true if successful
  Future<bool> _saveConfigFromEditorWithResult() async {
    if (_cachedConfigPath == null) {
      _log('No config path available for saving');
      return false;
    }

    String newContent = _configEditorController.text;
    // Normalize line endings: replace Windows "\r\n" with Unix "\n"
    newContent = newContent.replaceAll('\r\n', '\n');
    
    try {
      // Re-parse the config to update the parsed data first
      _parseConfigFile(newContent);
      
      // Check if this is an FTP path (for mDNS devices) or local path (for serial devices)
      if (_cachedConfigPath!.startsWith('ftp://')) {
        // Save to FTP server
        await _saveConfigToFtp(newContent);
        return true;
      } else {
        // Save to local file
        final File configFile = File(_cachedConfigPath!);
        await configFile.writeAsString(newContent);
        _handleConfigPersisted(newContent);
        
        _log('Configuration saved successfully');
        return true;
      }
    } catch (e) {
      _log('Error saving configuration: $e');
      return false;
    }
  }

  bool _canAddNewKey() {
    if (_selectedChapter == null || !_parsedConfig.containsKey(_selectedChapter)) {
      return false;
    }
    
    final List<String> availableKeys = _getAvailableKeysForChapter(_selectedChapter!);
    // Filter out SLOT_* keys as they cannot be added
    final List<String> addableKeys = availableKeys.where((String key) => !key.startsWith('SLOT_')).toList();
    return addableKeys.isNotEmpty;
  }

  SerialPort? _consolePort;
  Timer? _consoleTimer;
  final StringBuffer _consoleBuffer = StringBuffer();
  final ScrollController _consoleScrollController = ScrollController();

  Future<void> _startSerialConsole(String portName) async {
    await _stopSerialConsole();
    final SerialPort port = SerialPort(portName);
    try {
      if (!port.openReadWrite()) {
        _log('Console: cannot open $portName');
        port.dispose();
        return;
      }
      final SerialPortConfig config = port.config;
      config.baudRate = 115200;
      port.config = config;
      _consolePort = port;
      _consoleTimer = Timer.periodic(const Duration(milliseconds: 100), (Timer t) {
        if (_consolePort == null) return;
        try {
          final int available = _consolePort!.bytesAvailable;
          if (available > 0) {
            final Uint8List data = _consolePort!.read(available);
            _consoleBuffer.write(const Utf8Decoder(allowMalformed: true).convert(data));
            setState(() {});
          }
        } catch (e) {
          _log('Console: read error: $e');
        }
      });
    } catch (e) {
      _log('Console: error: $e');
      try { if (port.isOpen) port.close(); } catch (_) {}
      port.dispose();
    }
  }

  Future<void> _stopSerialConsole() async {
    try { _consoleTimer?.cancel(); } catch (_) {}
    _consoleTimer = null;
    try { if (_consolePort?.isOpen == true) _consolePort?.close(); } catch (_) {}
    try { _consolePort?.dispose(); } catch (_) {}
    _consolePort = null;
  }

  /// Invalidate current device selection
  void _invalidateCurrentDevice() {
    _log('Invalidate: Clearing device selection after restart command');
    
    // Stop console connection
    _stopSerialConsole();
    
    // Clear device selection and related cached data
    setState(() {
      _selected = null;
      _cachedConfigPath = null;
      _cachedConfigContent = null;
      _cachedManifestPath = null;
      _cachedManifestContent = null;
      _parsedConfig.clear();
      _configEditorController.clear();
      _selectedChapter = null;
    });
    
    _log('Invalidate: Device selection cleared');
  }

  @override
  void dispose() {
    _stopSerialConsole();
    _consoleScrollController.dispose();
    _logsScrollController.dispose();
    _suggestionScrollController.dispose();
    _configEditorController.dispose();
    _autocompleteTimer?.cancel();
    _overlayTimer?.cancel();
    _consoleAutocompleteTimer?.cancel();
    _hideSuggestionOverlay();
    _hideConsoleSuggestionOverlay();
    _consoleInputController.dispose();
    _consoleInputFocusNode.dispose();
    // Dispose config controllers
    for (final TextEditingController controller in _configControllers.values) {
      controller.dispose();
    }
    _detailsTabController.dispose();
    super.dispose();
  }

  final TextEditingController _consoleInputController = TextEditingController();

  /// Show console suggestion overlay
  void _showConsoleSuggestionOverlay(List<String> suggestions, String currentWord) {
    _hideConsoleSuggestionOverlay();
    
    if (suggestions.isEmpty) return;
    if (!mounted) return;
    
    // Wait for next frame to ensure widget tree is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isRebuilding || _isLayoutInProgress) return;
      
      if (!_consoleInputFocusNode.hasFocus) {
        _consoleInputFocusNode.requestFocus();
        Future.delayed(const Duration(milliseconds: 50), () {
          if (mounted && _consoleInputFocusNode.hasFocus) {
            _showConsoleSuggestionOverlayInternal(suggestions, currentWord);
          }
        });
        return;
      }
      
      if (_consoleInputFocusNode.context == null) return;
      
      _showConsoleSuggestionOverlayInternal(suggestions, currentWord);
    });
  }
  
  /// Internal method to actually show the overlay
  void _showConsoleSuggestionOverlayInternal(List<String> suggestions, String currentWord) {
    if (!mounted) return;
    
    final RenderBox? focusBox = _consoleInputFocusNode.context?.findRenderObject() as RenderBox?;
    if (focusBox == null) return;
    
    final Offset focusPosition = focusBox.localToGlobal(Offset.zero);
    final double popupWidth = 300.0;
    final double popupHeight = (suggestions.length * 40.0).clamp(80.0, 300.0);
    
    _consoleSuggestionOverlay = OverlayEntry(
      builder: (overlayContext) {
        final Size screenSize = MediaQuery.of(overlayContext).size;
        final double popupX = focusPosition.dx.clamp(0.0, screenSize.width - popupWidth);
        final double popupY = focusPosition.dy + focusBox.size.height + 4;
        
        return Positioned(
          left: popupX,
          top: popupY,
          width: popupWidth,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: BoxConstraints(maxHeight: popupHeight),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final bool isSelected = index == _consoleSelectedSuggestionIndex;
                  final String suggestion = suggestions[index];
                  return ListTile(
                    dense: true,
                    selected: isSelected,
                    title: Text(
                      suggestion,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    onTap: () => _selectConsoleSuggestion(suggestion, currentWord),
                    hoverColor: Colors.blue[50],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
    
    final BuildContext? overlayContext = _consoleInputFocusNode.context;
    if (overlayContext != null && _consoleSuggestionOverlay != null && mounted) {
      try {
        Overlay.of(overlayContext).insert(_consoleSuggestionOverlay!);
      } catch (e) {
        _log('Console: Error inserting suggestion overlay: $e');
        _consoleSuggestionOverlay = null;
      }
    } else if (mounted && _consoleSuggestionOverlay != null) {
      try {
        Overlay.of(context).insert(_consoleSuggestionOverlay!);
      } catch (e) {
        _log('Console: Error inserting suggestion overlay: $e');
        _consoleSuggestionOverlay = null;
      }
    }
  }

  /// Hide console suggestion overlay
  void _hideConsoleSuggestionOverlay() {
    if (_consoleSuggestionOverlay != null) {
      _consoleSuggestionOverlay!.remove();
      _consoleSuggestionOverlay = null;
    }
    _consoleSelectedSuggestionIndex = -1;
  }

  /// Select a console suggestion
  void _selectConsoleSuggestion(String suggestion, String currentWord) {
    final String text = _consoleInputController.text;
    
    String newText = text;
    
    // Determine where to insert based on the pattern
    if (text.contains('/')) {
      final List<String> parts = text.split('/');
      if (parts.length >= 2) {
        final String slotPart = parts[0];
        final String afterSlash = parts[1];
        
        if (afterSlash.contains(':')) {
          // Pattern: "slot/command:" -> replace value part
          final List<String> valueParts = afterSlash.split(':');
          final String commandPart = valueParts[0];
          newText = '$slotPart/$commandPart:$suggestion';
        } else {
          // Pattern: "slot/" -> replace command part
          newText = '$slotPart/$suggestion';
        }
      }
    } else {
      // Pattern: just text -> replace with slot
      newText = suggestion;
    }
    
    _consoleInputController.value = _consoleInputController.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    
    _hideConsoleSuggestionOverlay();
    Future.microtask(() {
      _consoleInputFocusNode.requestFocus();
    });
  }

  /// Handle keyboard events for console input suggestions
  KeyEventResult _handleConsoleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.enter && 
          _consoleSuggestionOverlay != null && 
          _consoleSuggestions.isNotEmpty && 
          _consoleSelectedSuggestionIndex >= 0) {
        _selectConsoleSuggestion(
          _consoleSuggestions[_consoleSelectedSuggestionIndex], 
          _consoleCurrentWord ?? ''
        );
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.escape && 
                 _consoleSuggestionOverlay != null) {
        _hideConsoleSuggestionOverlay();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown && 
                 _consoleSuggestionOverlay != null && 
                 _consoleSuggestions.isNotEmpty) {
        if (_consoleSelectedSuggestionIndex == -1) {
          _consoleSelectedSuggestionIndex = 0;
        } else if (_consoleSelectedSuggestionIndex < _consoleSuggestions.length - 1) {
          _consoleSelectedSuggestionIndex++;
        }
        if (_consoleSuggestionOverlay != null) {
          _consoleSuggestionOverlay!.markNeedsBuild();
        }
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp && 
                 _consoleSuggestionOverlay != null && 
                 _consoleSuggestions.isNotEmpty) {
        if (_consoleSelectedSuggestionIndex == -1) {
          _consoleSelectedSuggestionIndex = 0;
        } else if (_consoleSelectedSuggestionIndex > 0) {
          _consoleSelectedSuggestionIndex--;
        }
        if (_consoleSuggestionOverlay != null) {
          _consoleSuggestionOverlay!.markNeedsBuild();
        }
        return KeyEventResult.handled;
      } else if (_consoleSuggestionOverlay != null &&
                 (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                  event.logicalKey == LogicalKeyboardKey.arrowRight ||
                  event.logicalKey == LogicalKeyboardKey.home ||
                  event.logicalKey == LogicalKeyboardKey.end ||
                  event.logicalKey == LogicalKeyboardKey.pageUp ||
                  event.logicalKey == LogicalKeyboardKey.pageDown)) {
        _hideConsoleSuggestionOverlay();
      }
    }
    return KeyEventResult.ignored;
  }

  Widget _buildConsoleTab(DeviceItem item) {
    if (item.kind != 'serial') {
      return const Center(child: Text('Console available for serial devices only'));
    }

    // Ensure the console is connected to current selection
    if (_consolePort == null || (_consolePort != null && _consolePort!.name != item.identifier)) {
      // Kick off (non-blocking) start
      _startSerialConsole(item.identifier);
    }

    return Column(
      children: <Widget>[
        // Console output - takes all available space
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Scrollbar(
              controller: _consoleScrollController,
              child: SingleChildScrollView(
                controller: _consoleScrollController,
                reverse: true,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    _consoleBuffer.toString(),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Input row at bottom
        Row(
          children: <Widget>[
            Expanded(
              child: Focus(
                onKeyEvent: _handleConsoleKeyEvent,
                child: TextField(
                  controller: _consoleInputController,
                  focusNode: _consoleInputFocusNode,
                  decoration: const InputDecoration(
                    hintText: 'Enter command...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (String text) => _sendToSerial(text),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _sendToSerial(_consoleInputController.text),
              child: const Text('Send'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _consoleBuffer.clear();
                });
              },
              child: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }

  void _sendToSerial(String text) {
    if (_consolePort == null || !_consolePort!.isOpen || text.isEmpty) return;
    try {
      final List<int> message = utf8.encode('$text\n');
      _consolePort!.write(Uint8List.fromList(message));
      _consoleInputController.clear();
      _log('Console: sent "$text" to ${_consolePort!.name}');
    } catch (e) {
      _log('Console: send error: $e');
    }
  }

  /// Safely send restart command to serial port
  /// Returns true if command was sent successfully, false otherwise
  bool _sendRestartCommand() {
    // Don't send restart command during device scanning
    if (_isScanning) {
      _log('Restart: Cannot send command during device scanning');
      return false;
    }

    // Check if selected device is a serial device
    if (_selected == null || _selected!.kind != 'serial') {
      _log('Restart: Selected device is not a serial device');
      return false;
    }

    // Check if console port exists and is open
    if (_consolePort == null) {
      _log('Restart: Console port is not initialized');
      return false;
    }

    if (!_consolePort!.isOpen) {
      _log('Restart: Console port is not open');
      return false;
    }

    // Verify that the console port is connected to the selected device
    if (_consolePort!.name != _selected!.identifier) {
      _log('Restart: Console port (${_consolePort!.name}) does not match selected device (${_selected!.identifier})');
      return false;
    }

    // Send the restart command
    try {
      final List<int> message = utf8.encode('system/restart\n');
      _consolePort!.write(Uint8List.fromList(message));
      _log('Restart: Successfully sent "system/restart" to ${_consolePort!.name}');
      
      // Invalidate device after sending restart command
      _invalidateCurrentDevice();
      
      return true;
    } catch (e) {
      _log('Restart: Error sending command: $e');
      return false;
    }
  }

  Future<void> _loadDeviceFiles() async {
    _log('Loading device files from removable drives...');
    _cachedManifestContent = null;
    _cachedConfigContent = null;
    _cachedManifestPath = null;
    _cachedConfigPath = null;

    try {
      // Search for manifest-*.json files
      final String? manifestPath = await _findManifestFileInRemovableDrives();
      if (manifestPath != null) {
        _cachedManifestPath = manifestPath;
      _cachedManifestContent = await File(manifestPath).readAsString();
      _log('Loaded manifest file from: $_cachedManifestPath (${_cachedManifestContent!.length} chars)');
      _parseManifestFile(_cachedManifestContent!);
      } else {
        _log('No manifest-*.json files found on removable drives');
      }

      // Search for config.ini
      final String? configPath = await _findFileInRemovableDrives('config.ini');
      if (configPath != null) {
        _cachedConfigPath = configPath;
      _cachedConfigContent = await File(configPath).readAsString();
      // Normalize line endings: replace Windows "\r\n" with Unix "\n"
      _cachedConfigContent = _cachedConfigContent!.replaceAll('\r\n', '\n');
      _log('Loaded config.ini from: $configPath');
      _parseConfigFile(_cachedConfigContent!);
      
      // Initialize the text editor with the loaded content
      _synchronizeEditorWithCachedContent();
      // Rebuild cached suggestions with new config data
      _cachedSuggestions.clear();
      } else {
        _log('config.ini not found on removable drives');
      }
    } catch (e) {
      _log('Error loading device files: $e');
    }
  }

  Future<void> _loadDeviceFilesFromFtp(DeviceItem mdnsDevice) async {
    _log('Loading device files from FTP server for mDNS device: ${mdnsDevice.identifier}');
    _cachedManifestContent = null;
    _cachedConfigContent = null;
    _cachedManifestPath = null;
    _cachedConfigPath = null;

    try {
      // Extract IP address from device identifier (format: "ip:port")
      final String deviceIp = mdnsDevice.identifier.split(':')[0];
      
      _log('FTP: Connecting to $deviceIp:21 as anonymous');
      
      // Create FTP connection with simple settings
      final FTPConnect ftpConnect = FTPConnect(deviceIp, port: 21, user: 'anonymous', pass: '');
      final bool connected = await ftpConnect.connect();
      
      if (!connected) {
        _log('FTP: Failed to connect to $deviceIp:21');
        return;
      }
      
      _log('FTP: Successfully connected to $deviceIp:21');
      
      // Try different transfer modes if passive fails
      try {
        ftpConnect.transferMode = TransferMode.passive;
        _log('FTP: Passive mode enabled for data transfers');
      } catch (e) {
        _log('FTP: Failed to set passive mode, trying active mode: $e');
        try {
          ftpConnect.transferMode = TransferMode.active;
          _log('FTP: Active mode enabled for data transfers');
        } catch (e2) {
          _log('FTP: Failed to set transfer mode: $e2');
        }
      }

      try {
        // Search for manifest-*.json files on FTP
        final String? manifestFileName = await _findManifestFileInFtp(ftpConnect);
        if (manifestFileName != null) {
          _log('FTP: Found manifest file: $manifestFileName');
          
          // Download the manifest file
          final File tempManifestFile = File('./temp_manifest.json');
          final bool manifestDownloaded = await ftpConnect.downloadFile(manifestFileName, tempManifestFile);
          
          if (manifestDownloaded && await tempManifestFile.exists()) {
            _cachedManifestPath = 'ftp://$deviceIp/$manifestFileName';
            _cachedManifestContent = await tempManifestFile.readAsString();
            _log('FTP: Successfully downloaded manifest file (${_cachedManifestContent!.length} bytes)');
            _parseManifestFile(_cachedManifestContent!);
            
            // Clean up temporary manifest file
            try {
              await tempManifestFile.delete();
            } catch (_) {}
          } else {
            _log('FTP: Failed to download manifest file');
          }
        } else {
          _log('FTP: No manifest-*.json files found');
        }
      } catch (e) {
        _log('FTP: Error downloading manifest file: $e');
        
        // Fallback: Try direct download of common manifest files
        _log('FTP: Trying fallback direct download approach');
        final List<String> commonManifestNames = [
          'manifest.json',
          'manifest-3.31.json',
          'manifest-3.30.json',
          'manifest-1.0.json',
        ];
        
        for (final String manifestName in commonManifestNames) {
          try {
            _log('FTP: Trying direct download of $manifestName');
            final File tempManifestFile = File('./temp_manifest.json');
            final bool downloaded = await ftpConnect.downloadFile(manifestName, tempManifestFile);
            
            if (downloaded && await tempManifestFile.exists()) {
              _cachedManifestPath = 'ftp://$deviceIp/$manifestName';
              _cachedManifestContent = await tempManifestFile.readAsString();
              _log('FTP: Successfully downloaded manifest file via fallback (${_cachedManifestContent!.length} bytes)');
              _parseManifestFile(_cachedManifestContent!);
              
              try {
                await tempManifestFile.delete();
              } catch (_) {}
              break; // Success, exit the loop
            }
          } catch (e2) {
            _log('FTP: Fallback download failed for $manifestName: $e2');
          }
        }
      }

      try {
        // Load config.ini from FTP
        final File tempConfigFile = File('./temp_config.ini');
        final bool configDownloaded = await ftpConnect.downloadFile('config.ini', tempConfigFile);
        
        if (configDownloaded && await tempConfigFile.exists()) {
          _cachedConfigPath = 'ftp://$deviceIp/config.ini';
          _cachedConfigContent = await tempConfigFile.readAsString();
          // Normalize line endings: replace Windows "\r\n" with Unix "\n"
          _cachedConfigContent = _cachedConfigContent!.replaceAll('\r\n', '\n');
          _log('FTP: Successfully downloaded config.ini (${_cachedConfigContent!.length} bytes)');
          _parseConfigFile(_cachedConfigContent!);
          
          // Initialize the text editor with the loaded content
          _synchronizeEditorWithCachedContent();
          // Rebuild cached suggestions with new config data
          _cachedSuggestions.clear();
          
          // Clean up temporary config file
          try {
            await tempConfigFile.delete();
          } catch (_) {}
        } else {
          _log('FTP: Failed to download config.ini');
        }
      } catch (e) {
        _log('FTP: Error downloading config.ini: $e');
      }

      // Disconnect from FTP server
      try {
        await ftpConnect.disconnect();
        _log('FTP: Disconnected from server');
      } catch (_) {}
      
    } catch (e) {
      _log('FTP: Error loading device files: $e');
    }
  }

  Future<String?> _findManifestFileInRemovableDrives() async {
    // Search known removable roots recursively (depth-limited)
    for (final String root in _removableRoots) {
      final Directory dir = Directory(root);
      if (!await dir.exists()) continue;
      try {
        final String? found = await _findManifestFileInDir(dir, maxDepth: 5);
        if (found != null) {
          return found;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _findFileInRemovableDrives(String fileName) async {
    // Search known removable roots recursively (depth-limited)
    for (final String root in _removableRoots) {
      final Directory dir = Directory(root);
      if (!await dir.exists()) continue;
      try {
        final String? found = await _findFileInDir(dir, fileName, maxDepth: 5);
        if (found != null) {
          return found;
        }
      } catch (_) {}
    }
    
    // Additionally check common direct paths based on platform
    final List<String> commonCandidates = <String>[];
    
    if (Platform.isWindows) {
      // Windows: Check common removable drive locations
      for (int i = 0; i < 26; i++) {
        final String driveLetter = String.fromCharCode(65 + i); // A-Z
        commonCandidates.add('$driveLetter:\\$fileName');
      }
    } else {
      // Linux and macOS
      commonCandidates.addAll([
        '/media/$fileName',
        '/mnt/$fileName',
        '/Volumes/$fileName',
      ]);
    }
    
    for (final String c in commonCandidates) {
      final File f = File(c);
      if (await f.exists()) {
        return c;
      }
    }
    return null;
  }

  Future<String?> _findManifestFileInDir(Directory dir, {int maxDepth = 4}) async {
    if (maxDepth < 0) return null;
    try {
	_log("Searching in $dir");
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        final String path = entity.path;
        if (entity is File) {
          final String fileName = path.split(Platform.pathSeparator).last.toLowerCase();
          // Match manifest-*.json pattern
          if (fileName.startsWith('manifest-') && fileName.endsWith('.json')) {
            return path;
          }
        } else if (entity is Directory) {
          // Skip hidden/system directories to reduce noise
          final String name = path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;
          final String? nested = await _findManifestFileInDir(entity, maxDepth: maxDepth - 1);
          if (nested != null) return nested;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _findFileInDir(Directory dir, String fileName, {int maxDepth = 4}) async {
    if (maxDepth < 0) return null;
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        final String path = entity.path;
        if (entity is File) {
          if (path.split(Platform.pathSeparator).last.toLowerCase() == fileName.toLowerCase()) {
            return path;
          }
        } else if (entity is Directory) {
          // Skip hidden/system directories to reduce noise
          final String name = path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;
          final String? nested = await _findFileInDir(entity, fileName, maxDepth: maxDepth - 1);
          if (nested != null) return nested;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Find manifest file in FTP directory using wildcard pattern
  Future<String?> _findManifestFileInFtp(FTPConnect ftpConnect) async {
    try {
      _log('FTP: Attempting to list directory contents to find manifest files');
      
      // Try different listing methods
      List<dynamic> files = <dynamic>[];
      
      
      try {
        // Second try: NLST command (names only)
        _log('FTP: Trying NLST command');
        ftpConnect.listCommand = ListCommand.nlst;
        files = await ftpConnect.listDirectoryContent();
        _log('FTP: NLST successful, found ${files.length} files');
      } catch (e2) {
        _log('FTP: NLST failed: $e2');
       
        
        return null;
      }
      
      
      // Process files from successful listing
      _log('FTP: Processing ${files.length} files from directory listing');
      
      // Look for manifest files (any file containing "manifest" and ending with ".json")
      for (final dynamic file in files) {
        final String fileName = file.name?.toString() ?? '';
        _log('FTP: Checking file: $fileName');
        
        // Check if file matches manifest pattern (manifest-*.json)
        if (fileName.toLowerCase().contains('manifest') && fileName.toLowerCase().endsWith('.json')) {
          _log('FTP: Found matching manifest file: $fileName');
          return fileName;
        }
      }
      
      _log('FTP: No manifest files found in directory listing');
      return null;
    } catch (e) {
      _log('FTP: Error in manifest file search: $e');
      return null;
    }
  }

  void _parseManifestFile(String manifestContent) {
    try {
      _manifestData = jsonDecode(manifestContent) as Map<String, dynamic>;
      _availableKeys.clear();
      _chapterDescriptions.clear();
      _chapterWildcards.clear();
      
      _log('Manifest data keys: ${_manifestData.keys.toList()}');
      
      // Parse config array structure
      if (_manifestData.containsKey('config') && _manifestData['config'] is List) {
        final List<dynamic> configArray = _manifestData['config'] as List<dynamic>;
        _log('Found config array with ${configArray.length} items');
        
        for (final dynamic configItem in configArray) {
          if (configItem is Map<String, dynamic>) {
            final String? chapter = configItem['chapter']?.toString();
            final String? description = configItem['description']?.toString();
            _log('Processing chapter: $chapter with description: $description');
            
            if (chapter != null && configItem['values'] is List) {
              final List<dynamic> values = configItem['values'] as List<dynamic>;
              final List<String> keys = <String>[];
              _log('Found ${values.length} values for chapter $chapter');
              
              for (final dynamic valueItem in values) {
                if (valueItem is Map<String, dynamic> && valueItem['key'] != null) {
                  final String key = valueItem['key'].toString();
                  keys.add(key);
                  _log('Added key: $key');
                }
              }
              
              // Store chapter info
              _availableKeys[chapter] = keys;
              if (description != null) {
                _chapterDescriptions[chapter] = description;
              }
              _log('Chapter $chapter has keys: $keys');
            }
          }
        }
        
        // Match wildcard patterns to actual config chapters
        _matchWildcardsToConfigChapters();
      } else {
        _log('No config array found in manifest');
      }
      
      _log('Parsed manifest with ${_availableKeys.length} chapters: ${_availableKeys.keys.toList()}');
    } catch (e) {
      _log('Error parsing manifest: $e');
      _manifestData = <String, dynamic>{};
      _availableKeys.clear();
      _chapterDescriptions.clear();
      _chapterWildcards.clear();
    }
  }

  void _matchWildcardsToConfigChapters() {
    // Match manifest wildcard patterns to actual config.ini chapters
    for (final String manifestChapter in _availableKeys.keys) {
      if (manifestChapter.contains('*')) {
        // This is a wildcard pattern
        final String pattern = manifestChapter.replaceAll('*', '.*');
        final RegExp regex = RegExp('^$pattern\$', caseSensitive: false);
        
        for (final String configChapter in _parsedConfig.keys) {
          if (regex.hasMatch(configChapter)) {
            _chapterWildcards[configChapter] = manifestChapter;
            _log('Matched wildcard "$manifestChapter" to config chapter "$configChapter"');
          }
        }
      } else {
        // Direct match
        if (_parsedConfig.containsKey(manifestChapter)) {
          _chapterWildcards[manifestChapter] = manifestChapter;
          _log('Direct match for chapter "$manifestChapter"');
        }
      }
    }
  }


  List<String> _getAvailableKeysForChapter(String chapter) {
    // Find the manifest chapter that matches this config chapter
    final String? manifestChapter = _chapterWildcards[chapter];
    if (manifestChapter == null) {
      _log('No manifest chapter found for config chapter "$chapter"');
      return <String>[];
    }
    
    // Get keys from manifest that are not already in the config
    final List<String> manifestKeys = _availableKeys[manifestChapter] ?? <String>[];
    final List<String> existingKeys = _parsedConfig[chapter]?.keys.toList() ?? <String>[];
    
    _log('Available keys for chapter "$chapter" (from manifest "$manifestChapter"): $manifestKeys');
    _log('Existing keys in config: $existingKeys');
    
    // Return keys that are in manifest but not in current config
    // Exclude SLOT_* keys as they cannot be added
    final List<String> availableKeys = manifestKeys.where((String key) => 
        !existingKeys.contains(key) && !key.startsWith('SLOT_')).toList();
    _log('Filtered available keys (excluding SLOT_*): $availableKeys');
    
    return availableKeys;
  }

  Map<String, dynamic>? _getKeyInfo(String chapter, String key) {
    // Find the manifest chapter that matches this config chapter
    final String? manifestChapter = _chapterWildcards[chapter];
    if (manifestChapter == null) {
      return null;
    }
    
    if (_manifestData.containsKey('config') && _manifestData['config'] is List) {
      final List<dynamic> configArray = _manifestData['config'] as List<dynamic>;
      for (final dynamic configItem in configArray) {
        if (configItem is Map<String, dynamic>) {
          final String? itemChapter = configItem['chapter']?.toString();
          if (itemChapter == manifestChapter && configItem['values'] is List) {
            final List<dynamic> values = configItem['values'] as List<dynamic>;
            for (final dynamic valueItem in values) {
              if (valueItem is Map<String, dynamic> && 
                  valueItem['key']?.toString() == key) {
                return valueItem;
              }
            }
          }
        }
      }
    }
    return null;
  }

  void _handleDesignControllerChanged(String chapter, String key, String newValue) {
    if (_suspendDesignDirtyTracking) return;
    if (!_parsedConfig.containsKey(chapter)) return;

    final String? currentValue = _parsedConfig[chapter]?[key];
    if (currentValue == newValue) {
      return;
    }

    _parsedConfig[chapter]![key] = newValue;
    _refreshDesignDirtyState();
  }

  Map<String, Map<String, String>> _cloneParsedConfig(Map<String, Map<String, String>> source) {
    final Map<String, Map<String, String>> clone = <String, Map<String, String>>{};
    for (final MapEntry<String, Map<String, String>> entry in source.entries) {
      clone[entry.key] = Map<String, String>.from(entry.value);
    }
    return clone;
  }

  bool _areParsedConfigsEqual(Map<String, Map<String, String>> a, Map<String, Map<String, String>> b) {
    if (a.length != b.length) {
      return false;
    }

    for (final String chapter in a.keys) {
      final Map<String, String>? aChapter = a[chapter];
      final Map<String, String>? bChapter = b[chapter];
      if (bChapter == null) {
        return false;
      }
      if (aChapter!.length != bChapter.length) {
        return false;
      }
      for (final String key in aChapter.keys) {
        if (aChapter[key] != bChapter[key]) {
          return false;
        }
      }
    }

    return true;
  }

  void _refreshDesignDirtyState() {
    final bool newDirty = !_areParsedConfigsEqual(_parsedConfig, _originalParsedConfig);
    if (_isConfigDesignDirty != newDirty) {
      if (mounted) {
        setState(() {
          _isConfigDesignDirty = newDirty;
        });
      } else {
        _isConfigDesignDirty = newDirty;
      }
    }
  }

  void _refreshParsedConfigFromEditor() {
    final String editorContent = _configEditorController.text;
    _parseConfigFile(editorContent, updateBaseline: false);
  }

  void _synchronizeEditorWithCachedContent() {
    if (_cachedConfigContent == null) {
      return;
    }

    _suspendEditorDirtyTracking = true;
    _configEditorController.text = _cachedConfigContent!;
    _lastText = _cachedConfigContent!;
    _lastSelection = _configEditorController.selection;
    _suspendEditorDirtyTracking = false;
    _refreshEditorDirtyState();
  }

  void _handleConfigPersisted(String configContent) {
    _cachedConfigContent = configContent;
    _originalParsedConfig = _cloneParsedConfig(_parsedConfig);
    _refreshDesignDirtyState();
    _synchronizeEditorWithCachedContent();
  }

  String _buildConfigContentFromParsedConfig() {
    final StringBuffer buffer = StringBuffer();
    for (final String chapter in _parsedConfig.keys) {
      buffer.write('[$chapter]\n');
      for (final MapEntry<String, String> entry in _parsedConfig[chapter]!.entries) {
        buffer.write('${entry.key}=${entry.value}\n');
      }
      buffer.write('\n');
    }
    return buffer.toString();
  }

  void _syncEditorFromParsedConfig() {
    final String configContent = _buildConfigContentFromParsedConfig();
    if (_configEditorController.text == configContent) {
      return;
    }

    _suspendEditorDirtyTracking = true;
    _configEditorController.text = configContent;
    _lastText = configContent;
    _lastSelection = _configEditorController.selection;
    _suspendEditorDirtyTracking = false;
    _refreshEditorDirtyState(currentText: configContent);
  }

  Widget _buildSaveButton(VoidCallback? onPressed) {
    // Check if this is for a serial device
    final bool isSerialDevice = _selected?.kind == 'serial';
    
    // If serial device and has save callback, support long-press
    if (isSerialDevice && onPressed != null) {
      return GestureDetector(
        onLongPressStart: (_) {
          setState(() {
            _isSaveButtonLongPressed = true;
          });
        },
        onLongPressEnd: (_) async {
          setState(() {
            _isSaveButtonLongPressed = false;
          });
          
          // Determine which save method to use based on current tab
          bool saveSuccess = false;
          if (_currentDetailsTabIndex == 0) {
            // Config edit tab
            saveSuccess = await _saveConfigFromEditorWithResult();
          } else if (_currentDetailsTabIndex == 1) {
            // Config design tab
            saveSuccess = await _saveConfigToFileWithResult();
          }
          
          // If save was successful, send restart command
          if (saveSuccess) {
            // Add a small delay to ensure file write is complete
            await Future.delayed(const Duration(milliseconds: 100));
            _sendRestartCommand();
          }
        },
        child: FilledButton.icon(
          // Disable regular press when long-pressing to prevent double-save
          onPressed: _isSaveButtonLongPressed ? null : onPressed,
          icon: const Icon(Icons.save),
          label: Text(_isSaveButtonLongPressed ? 'Save/Restart' : 'Save'),
        ),
      );
    }
    
    // Regular button for non-serial devices or when no callback
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.save),
      label: const Text('Save'),
    );
  }

  void _parseConfigFile(String configContent, {bool updateBaseline = true}) {
    final String? previousSelection = _selectedChapter;
    _parsedConfig.clear();
    _selectedChapter = null;
    
    // Clear existing controllers
    for (final TextEditingController controller in _configControllers.values) {
      controller.dispose();
    }
    _configControllers.clear();

    final List<String> lines = configContent.split('\n');
    String? currentChapter;
    
    for (final String line in lines) {
      final String trimmedLine = line.trim();
      
      // Skip empty lines and comments
      if (trimmedLine.isEmpty || trimmedLine.startsWith('#')) {
        continue;
      }
      
      // Check for chapter header [chapter_name]
      if (trimmedLine.startsWith('[') && trimmedLine.endsWith(']')) {
        currentChapter = trimmedLine.substring(1, trimmedLine.length - 1);
        _parsedConfig[currentChapter] = <String, String>{};
        continue;
      }
      
      // Parse key=value pairs
      if (currentChapter != null && trimmedLine.contains('=')) {
        final int equalIndex = trimmedLine.indexOf('=');
        final String key = trimmedLine.substring(0, equalIndex).trim();
        final String value = trimmedLine.substring(equalIndex + 1).trim();
        _parsedConfig[currentChapter]![key] = value;
      }
    }
    
    // Set first chapter as selected if available
    if (_parsedConfig.isNotEmpty) {
      if (previousSelection != null && _parsedConfig.containsKey(previousSelection)) {
        _selectedChapter = previousSelection;
      } else {
        _selectedChapter = _parsedConfig.keys.first;
      }
      _suspendDesignDirtyTracking = true;
      _updateConfigControllers();
      _suspendDesignDirtyTracking = false;
    }
    
    // Match wildcards after config is parsed
    if (_manifestData.isNotEmpty) {
      _matchWildcardsToConfigChapters();
    }
    
    if (updateBaseline) {
      _originalParsedConfig = _cloneParsedConfig(_parsedConfig);
    }
    _refreshDesignDirtyState();

    _log('Parsed config with ${_parsedConfig.length} chapters');
  }

  void _updateConfigControllers() {
    if (_selectedChapter == null || !_parsedConfig.containsKey(_selectedChapter)) {
      return;
    }
    
    for (final TextEditingController controller in _configControllers.values) {
      controller.dispose();
    }
    _configControllers.clear();

    final Map<String, String> chapterData = _parsedConfig[_selectedChapter!]!;
    final String chapter = _selectedChapter!;
    
    // Create controllers for this chapter
    for (final MapEntry<String, String> entry in chapterData.entries) {
      final String key = entry.key;
      final TextEditingController controller = TextEditingController(text: entry.value);
      controller.addListener(() {
        if (!mounted) return;
        _handleDesignControllerChanged(chapter, key, controller.text);
      });
      _configControllers[key] = controller;
    }

    if (!_suspendDesignDirtyTracking) {
      _refreshDesignDirtyState();
    }
  }

  Future<void> _showAddKeyDialog() async {
    if (_selectedChapter == null || !_parsedConfig.containsKey(_selectedChapter)) {
      return;
    }

    // Get available keys for the selected chapter
    final List<String> availableKeys = _getAvailableKeysForChapter(_selectedChapter!);
    String? selectedKey;
    String? selectedValue;
    final TextEditingController valueController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: const Text('Add New Key/Value'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  DropdownButtonFormField<String>(
                    value: selectedKey,
                    decoration: const InputDecoration(
                      labelText: 'Key Name',
                      border: OutlineInputBorder(),
                    ),
                    items: availableKeys.map((String key) {
                      return DropdownMenuItem<String>(
                        value: key,
                        child: Text(key),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      setState(() {
                        selectedKey = newValue;
                        if (newValue != null) {
                          final Map<String, dynamic>? keyInfo = _getKeyInfo(_selectedChapter!, newValue);
                          if (keyInfo != null) {
                            // Check for default value
                            selectedValue = keyInfo['default']?.toString() ?? '';
                            
                            // If no default but has spec type, use first available option
                            if (selectedValue?.isEmpty == true && keyInfo['spec'] != null) {
                              final String specType = keyInfo['spec'].toString();
                              if (specType == 'slot_mode') {
                                final List<Map<String, dynamic>> modeOptions = _getModeOptions();
                                if (modeOptions.isNotEmpty) {
                                  selectedValue = modeOptions.first['mode']?.toString() ?? '';
                                }
                              }
                            }
                            
                            valueController.text = selectedValue ?? '';
                          }
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (selectedKey != null) _buildValueInput(selectedKey!, valueController),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selectedKey != null ? () {
                    _addNewKeyValue(selectedKey!, valueController.text);
                    Navigator.of(context).pop();
                  } : null,
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddSlotChapterDialog() {
    // Find available SLOT numbers (0-9)
    final List<int> availableNumbers = <int>[];
    for (int i = 0; i <= 9; i++) {
      final String chapterName = 'SLOT_$i';
      if (!_parsedConfig.containsKey(chapterName)) {
        availableNumbers.add(i);
      }
    }
    
    if (availableNumbers.isEmpty) {
      _log('No available SLOT numbers (0-9)');
      return;
    }
    
    int? selectedNumber;
    
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: const Text('Add SLOT Chapter'),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    DropdownButtonFormField<int>(
                      value: selectedNumber,
                      decoration: const InputDecoration(
                        labelText: 'SLOT Number',
                        border: OutlineInputBorder(),
                      ),
                      items: availableNumbers.map((int number) {
                        return DropdownMenuItem<int>(
                          value: number,
                          child: Text('SLOT_$number'),
                        );
                      }).toList(),
                      onChanged: (int? newValue) {
                        setState(() {
                          selectedNumber = newValue;
                        });
                      },
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selectedNumber != null ? () {
                    _createSlotChapter(selectedNumber!);
                    Navigator.of(context).pop();
                  } : null,
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _createSlotChapter(int slotNumber) {
    final String chapterName = 'SLOT_$slotNumber';
    
    // Create the new chapter with all standard fields
    _parsedConfig[chapterName] = <String, String>{};
    
    // Get standard fields for SLOT_* from manifest
    final String? manifestChapter = _availableKeys.keys.firstWhere(
      (String chapter) => chapter.startsWith('SLOT_') || chapter == 'SLOT_*',
      orElse: () => '',
    );
    
    if (manifestChapter != null && manifestChapter.isNotEmpty) {
      final List<String> standardFields = _availableKeys[manifestChapter] ?? <String>[];
      
      // Add all standard fields with "empty" values
      for (final String field in standardFields) {
        _parsedConfig[chapterName]![field] = 'empty';
      }
      
      _log('Created new SLOT chapter: $chapterName with ${standardFields.length} fields');
    } else {
      _log('Created new SLOT chapter: $chapterName (no manifest fields found)');
    }
    
    // Update the chapter dropdown
    setState(() {
      _selectedChapter = chapterName;
      _updateConfigControllers();
    });

    _refreshDesignDirtyState();
  }

  bool _isSlotChapterSelected() {
    return _selectedChapter != null && _selectedChapter!.startsWith('SLOT_');
  }

  void _showDeleteSlotChapterDialog() {
    if (_selectedChapter == null || !_selectedChapter!.startsWith('SLOT_')) {
      return;
    }

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete SLOT Chapter'),
          content: Text('Are you sure you want to delete "$_selectedChapter"? This action cannot be undone.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _deleteSlotChapter();
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _deleteSlotChapter() {
    if (_selectedChapter == null || !_selectedChapter!.startsWith('SLOT_')) {
      return;
    }

    final String chapterToDelete = _selectedChapter!;
    
    // Remove the chapter from parsed config
    _parsedConfig.remove(chapterToDelete);
    
    // Clear controllers for this chapter
    for (final String key in _configControllers.keys.toList()) {
      _configControllers[key]?.dispose();
      _configControllers.remove(key);
    }
    
    // Select a different chapter if available
    String? newSelection;
    if (_parsedConfig.isNotEmpty) {
      newSelection = _parsedConfig.keys.first;
    }
    
    setState(() {
      _selectedChapter = newSelection;
      if (newSelection != null) {
        _updateConfigControllers();
      }
    });
    
    _log('Deleted SLOT chapter: $chapterToDelete');
    _refreshDesignDirtyState();
  }

  void _showAddOptionDialog() {
    if (_selectedChapter == null || !_selectedChapter!.startsWith('SLOT_')) {
      return;
    }

    // Get current mode value
    final String? currentMode = _configControllers['mode']?.text;
    if (currentMode == null || currentMode.isEmpty) {
      _log('No mode selected for options');
      return;
    }

    // Get options for the current mode from manifest
    final List<Map<String, dynamic>> availableOptions = _getOptionsForMode(currentMode);
    if (availableOptions.isEmpty) {
      _log('No options available for mode: $currentMode');
      return;
    }

    Map<String, dynamic>? selectedOption;
    
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: const Text('Add Option'),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('Mode: $currentMode'),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<Map<String, dynamic>>(
                      value: selectedOption,
                      decoration: const InputDecoration(
                        labelText: 'Select Option',
                        border: OutlineInputBorder(),
                      ),
                      items: availableOptions.map((Map<String, dynamic> option) {
                        final String name = option['name']?.toString() ?? '';
                        final String description = option['description']?.toString() ?? '';
                        final String displayText = description.isNotEmpty ? '$name - $description' : name;
                        
                        return DropdownMenuItem<Map<String, dynamic>>(
                          value: option,
                          child: Text(displayText),
                        );
                      }).toList(),
                      onChanged: (Map<String, dynamic>? newValue) {
                        setState(() {
                          selectedOption = newValue;
                        });
                      },
                    ),
                    if (selectedOption != null) ...[
                      const SizedBox(height: 16),
                      _buildOptionValueInput(selectedOption!),
                    ],
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selectedOption != null ? () {
                    _addOptionToOptions(selectedOption!);
                    Navigator.of(context).pop();
                  } : null,
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<Map<String, dynamic>> _getOptionsForMode(String mode) {
    final List<Map<String, dynamic>> options = <Map<String, dynamic>>[];
    
    // Look for options in manifest based on mode
    if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
      final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
      for (final dynamic modeItem in modesArray) {
        if (modeItem is Map<String, dynamic> && 
            modeItem['mode']?.toString() == mode &&
            modeItem['options'] is List) {
          final List<dynamic> modeOptions = modeItem['options'] as List<dynamic>;
          for (final dynamic option in modeOptions) {
            if (option is Map<String, dynamic>) {
              options.add(option);
            }
          }
        }
      }
    }
    
    _log('Found ${options.length} options for mode: $mode');
    return options;
  }

  Widget _buildOptionValueInput(Map<String, dynamic> option) {
    final String name = option['name']?.toString() ?? '';
    final String description = option['description']?.toString() ?? '';
    final String valueType = option['valueType']?.toString() ?? 'string';
    final dynamic defaultValue = option['valueDefault'];
    final dynamic minValue = option['valueMin'];
    final dynamic maxValue = option['valueMax'];
    final String unit = option['unit']?.toString() ?? '';
    
    final TextEditingController valueController = TextEditingController(
      text: defaultValue?.toString() ?? '',
    );
    
    // Store the controller in the option for later access
    option['_valueController'] = valueController;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('$name: $description', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: valueController,
                decoration: InputDecoration(
                  labelText: 'Value',
                  hintText: 'Enter $valueType value',
                  border: const OutlineInputBorder(),
                  suffixText: unit.isNotEmpty ? unit : null,
                ),
                keyboardType: valueType == 'int' ? TextInputType.number : 
                             valueType == 'float' ? const TextInputType.numberWithOptions(decimal: true) : 
                             TextInputType.text,
              ),
            ),
          ],
        ),
        if (minValue != null || maxValue != null) ...[
          const SizedBox(height: 4),
          Text(
            'Range: ${minValue ?? 'no min'} - ${maxValue ?? 'no max'}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ],
    );
  }

  void _addOptionToOptions(Map<String, dynamic> option) {
    if (_selectedChapter == null || !_selectedChapter!.startsWith('SLOT_')) {
      return;
    }

    final String name = option['name']?.toString() ?? '';
    final TextEditingController? valueController = option['_valueController'] as TextEditingController?;
    final String value = valueController?.text.trim() ?? option['valueDefault']?.toString() ?? '';
    
    if (value.isEmpty) {
      _log('No value provided for option: $name');
      return;
    }
    
    final TextEditingController? optionsController = _configControllers['options'];
    final String currentOptions = optionsController?.text ?? '';
    final String newOption = '$name:$value';
    final String newOptions = currentOptions.isEmpty ? newOption : '$currentOptions,$newOption';
    
    if (optionsController != null) {
      optionsController.text = newOptions;
    } else {
      _parsedConfig[_selectedChapter!]!['options'] = newOptions;
      _refreshDesignDirtyState();
    }
    
    _log('Added option "$newOption" to options field');
  }

  void _showAddCrossLinkRuleDialog() {
    if (_selectedChapter == null) {
      return;
    }

    String? sourceSlot;
    String? sourceReport = '';
    String? targetSlot;
    String? targetCommand = '';
    final TextEditingController sourceValueController = TextEditingController();
    final TextEditingController ruleValueController = TextEditingController();
    
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: const Text('Add Cross Link Rule'),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // Source slot selection
                    DropdownButtonFormField<String>(
                      value: sourceSlot,
                      decoration: const InputDecoration(
                        labelText: 'Source Slot',
                        border: OutlineInputBorder(),
                      ),
                      items: _getTopicBasedSourceSlots().map((String slot) {
                        return DropdownMenuItem<String>(
                          value: slot,
                          child: Text(slot),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          sourceSlot = newValue;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    // Source report selection
                    DropdownButtonFormField<String>(
                      value: sourceReport,
                      decoration: const InputDecoration(
                        labelText: 'Source Report',
                        border: OutlineInputBorder(),
                      ),
                      items: _getReportTopicsForCurrentMode().map((String topic) {
                        return DropdownMenuItem<String>(
                          value: topic,
                          child: Text(topic),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          sourceReport = newValue;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    // Source value input
                    TextField(
                      controller: sourceValueController,
                      decoration: const InputDecoration(
                        labelText: 'Source Value',
                        hintText: 'Enter source value or condition',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Target slot selection
                    DropdownButtonFormField<String>(
                      value: targetSlot,
                      decoration: const InputDecoration(
                        labelText: 'Target Slot',
                        border: OutlineInputBorder(),
                      ),
                      items: _getTopicBasedSourceSlots().map((String slot) {
                        return DropdownMenuItem<String>(
                          value: slot,
                          child: Text(slot),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          targetSlot = newValue;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    // Target command selection
                    DropdownButtonFormField<String>(
                      value: targetCommand,
                      decoration: const InputDecoration(
                        labelText: 'Target Command',
                        border: OutlineInputBorder(),
                      ),
                      items: _getTargetCommandsForSlot(targetSlot).map((String command) {
                        return DropdownMenuItem<String>(
                          value: command,
                          child: Text(command.isEmpty ? '' : command),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          targetCommand = newValue;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    // Target value input
                    TextField(
                      controller: ruleValueController,
                      decoration: const InputDecoration(
                        labelText: 'Target Value',
                        hintText: 'Enter target value or condition',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: (sourceSlot != null && targetSlot != null) ? () {
                    _addCrossLinkRule(sourceSlot!, sourceReport, sourceValueController.text, targetSlot!, targetCommand, ruleValueController.text);
                    Navigator.of(context).pop();
                  } : null,
                  child: const Text('Add Rule'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Get topic-based complex values for source slot selection
  /// Format: topic_value_slot_number (e.g., sensor_data_1, control_signal_2)
  List<String> _getTopicBasedSourceSlots() {
    final List<String> complexSlots = <String>[];
    final Set<String> uniqueComplexSlots = <String>{};
    
    // Debug info removed for production
    
    // Get all SLOT_* chapters
    for (final String chapter in _parsedConfig.keys) {
      if (chapter.startsWith('SLOT_')) {
        // Extract slot number from chapter name (e.g., "SLOT_1" -> "1")
        final String slotNumber = _extractSlotNumber(chapter);
        if (slotNumber.isEmpty) continue;
        
        // Get topic values from this slot's options field
        final List<String> topicValues = _getTopicValuesFromSlotSilent(chapter);
        
        if (topicValues.isNotEmpty) {
          // Create complex values: topic_value_slot_number
          for (final String topicValue in topicValues) {
            String complexSlot;
            
            // Check if the topic value already has underscore and number at the end
            if (_hasUnderscoreAndNumberAtEnd(topicValue)) {
              // Use the value as-is if it already has underscore+number
              complexSlot = topicValue;
            } else {
              // Add slot number if it doesn't have underscore+number
              complexSlot = '${topicValue}_$slotNumber';
            }
            
            if (uniqueComplexSlots.add(complexSlot)) {
              complexSlots.add(complexSlot);
            }
          }
        }
      }
    }
    
    // // Add current chapter if it's not a SLOT chapter
    // if (_selectedChapter != null && !_selectedChapter!.startsWith('SLOT_')) {
    //   complexSlots.add(_selectedChapter!);
    // }
    
    return complexSlots;
  }

  /// Extract slot number from chapter name (e.g., "SLOT_1" -> "1")
  String _extractSlotNumber(String chapterName) {
    if (!chapterName.startsWith('SLOT_')) return '';
    
    final String numberPart = chapterName.substring(5); // Remove "SLOT_"
    // Validate that it's a number
    if (int.tryParse(numberPart) != null) {
      return numberPart;
    }
    return '';
  }

  /// Check if a string has underscore and number at the end (e.g., "value_1", "data_42")
  bool _hasUnderscoreAndNumberAtEnd(String value) {
    final RegExp underscoreNumberRegex = RegExp(r'_\d+$');
    return underscoreNumberRegex.hasMatch(value);
  }

  /// Get topic variable values from a slot's options field (without logging)
  List<String> _getTopicValuesFromSlotSilent(String slotChapter) {
    final List<String> topicValues = <String>[];
    
    try {
      // First, try to get topic variables from the slot's options field
      final String? optionsValue = _parsedConfig[slotChapter]?['options'];
      
      if (optionsValue != null && optionsValue.isNotEmpty) {
        // Parse the options value (assuming it's a comma-separated list or JSON array)
        List<dynamic> options = <dynamic>[];
        
        // Try to parse as JSON first
        try {
          options = jsonDecode(optionsValue) as List<dynamic>;
        } catch (_) {
          // If not JSON, try comma-separated values
          final List<String> parts = optionsValue.split(',').map((e) => e.trim()).toList();
          options = parts.where((part) => part.isNotEmpty).toList();
        }
        
        // Look for variables containing "topic" and extract their values
        for (final dynamic option in options) {
          final String optionStr = option.toString();
          
          if (optionStr.toLowerCase().contains('topic')) {
            String topicValue;
            
            if (optionStr.contains(':')) {
              // Extract the value after ':' (e.g., "testTopic:bebe_0" -> "bebe_0")
              topicValue = optionStr.split(':')[1].trim();
            } else {
              // If no ':' sign, treat the whole string as the topic value
              topicValue = optionStr.trim();
            }
            
            // Clean up the topic value (remove any extra characters)
            topicValue = topicValue.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
            
            if (topicValue.isNotEmpty && !topicValues.contains(topicValue)) {
              topicValues.add(topicValue);
            }
          }
        }
      }
      
      // If no topic variables found in options, try to get default values from manifest.json
      if (topicValues.isEmpty) {
        // Try to get mode from text editor first (real-time), then fall back to parsed config
        String? modeValue = _getModeFromTextEditor(slotChapter);
        if (modeValue == null || modeValue.isEmpty) {
          modeValue = _parsedConfig[slotChapter]?['mode'];
        }
        
        if (modeValue != null && modeValue.isNotEmpty) {
          final String slotNumber = _extractSlotNumber(slotChapter);
          final List<String> manifestDefaults = _getTopicDefaultsFromManifest(modeValue, slotNumber);
          topicValues.addAll(manifestDefaults);
        }
      }
    } catch (e) {
      // Silent error handling during build
    }
    return topicValues;
  }

  /// Get topic default values from manifest.json for a specific mode
  List<String> _getTopicDefaultsFromManifest(String mode, String slotNumber) {
    final List<String> topicDefaults = <String>[];
    
    try {
      if (_manifestData.isEmpty) {
        return topicDefaults;
      }
      
      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            
            if (modeName == mode && modeItem['options'] is List) {
              final List<dynamic> modeOptions = modeItem['options'] as List<dynamic>;
              
              for (final dynamic option in modeOptions) {
                if (option is Map<String, dynamic>) {
                  final String? name = option['name']?.toString();
                  final String? defaultValue = option['valueDefault']?.toString();
                  
                  // Look for options whose names contain "topic" and have defaultValue
                  if (name != null && name.toLowerCase().contains('topic') && defaultValue != null && defaultValue != 'null') {
                    // Clean up the default value (preserve meaningful characters, only replace problematic ones)
                    String cleanValue = defaultValue
                        .replaceAll(RegExp(r'^/+'), '')       // Remove leading forward slashes
                        .replaceAll(RegExp(r'[^\w\-]'), '_')  // Replace only problematic chars, keep alphanumeric, underscore, hyphen
                        .replaceAll(RegExp(r'^_+'), '')       // Remove leading underscores
                        .replaceAll(RegExp(r'_+$'), '')       // Remove trailing underscores
                        .replaceAll(RegExp(r'_+'), '_');      // Replace multiple underscores with single
                    
                    print('DEBUG: "$defaultValue" -> "$cleanValue"');
                    
                    // Check if the value already has underscore and number at the end
                    if (_hasUnderscoreAndNumberAtEnd(cleanValue)) {
                      // Replace the existing number with the correct slot number
                      cleanValue = _replaceSlotNumber(cleanValue, slotNumber);
                    } else {
                      // Add slot number if it doesn't have underscore+number
                      cleanValue = '${cleanValue}_$slotNumber';
                    }
                    
                    if (cleanValue.isNotEmpty && !topicDefaults.contains(cleanValue)) {
                      topicDefaults.add(cleanValue);
                    }
                  }
                }
              }
              break; // Found the mode, no need to continue
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling during build
    }
    return topicDefaults;
  }

  /// Replace the slot number in a value that already has underscore+number
  String _replaceSlotNumber(String value, String newSlotNumber) {
    // Remove the existing underscore+number at the end
    final RegExp underscoreNumberRegex = RegExp(r'_\d+$');
    final String baseValue = value.replaceAll(underscoreNumberRegex, '');
    
    // Add the new slot number
    return '${baseValue}_$newSlotNumber';
  }

  /// Get step-by-step cross link suggestions based on current input
  List<String> _getCrossLinkStepByStepSuggestions(String currentInput) {
    final List<String> suggestions = <String>[];
    _log('DEBUG: _getCrossLinkStepByStepSuggestions called with: "$currentInput"');
    
    if (currentInput == 'cross_link') {
      // Step 1: Show source slots
      final List<String> sourceSlots = _getTopicBasedSourceSlots();
      for (final String slot in sourceSlots) {
        suggestions.add(slot);
      }
    } else if (currentInput.startsWith('cross_link=')) {
      final String crossLinkValue = currentInput.substring(11); // Remove 'cross_link=' prefix
      _log('DEBUG: Cross link value: "$crossLinkValue"');
      final CrossLinkStepType stepType = _parseCrossLinkStep(crossLinkValue);
      _log('DEBUG: Detected step type: $stepType');
      
      switch (stepType) {
        case CrossLinkStepType.sourceSlot:
          // Step 1: Show source slots
          final List<String> sourceSlots = _getTopicBasedSourceSlots();
          for (final String slot in sourceSlots) {
            if (slot.toLowerCase().contains(crossLinkValue.toLowerCase())) {
              // Don't suggest if it exactly matches what's already typed
              if (slot.toLowerCase() != crossLinkValue.toLowerCase()) {
                suggestions.add(slot);
              }
            }
          }
          break;
          
        case CrossLinkStepType.sourceReport:
          // Step 2: Show source reports
          _log('DEBUG: Processing source report step - TRIGGERED BY / TYPING');
          final String sourceSlot = _extractSourceSlotFromCrossLink(crossLinkValue);
          _log('DEBUG: Source slot extracted: "$sourceSlot"');
          final List<String> reports = _getReportTopicsForSourceSlot(sourceSlot);
          _log('DEBUG: Found ${reports.length} reports for source slot "$sourceSlot"');
          final String filterText = _extractFilterTextAfterSlash(crossLinkValue);
          _log('DEBUG: Filter text after slash: "$filterText"');
          
          for (final String report in reports) {
            if (report.isNotEmpty && (filterText.isEmpty || report.toLowerCase().contains(filterText.toLowerCase()))) {
              // Don't suggest if it exactly matches what's already typed
              if (filterText.isEmpty || report.toLowerCase() != filterText.toLowerCase()) {
                suggestions.add(report);
                _log('DEBUG: Added source report suggestion: "$report"');
              }
            }
          }
          _log('DEBUG: Total source report suggestions: ${suggestions.length}');
          break;
          
        case CrossLinkStepType.sourceValue:
          // Step 3: Show source values (topic variables from source slot)
          final String sourceSlot = _extractSourceSlotFromCrossLink(crossLinkValue);
          final List<String> topicValues = _getTopicValuesFromSlotSilent(sourceSlot);
          final String currentValue = _extractCurrentValueFromCrossLink(crossLinkValue);
          
          for (final String value in topicValues) {
            // Don't suggest if it exactly matches what's already typed
            if (value.toLowerCase() != currentValue.toLowerCase()) {
              suggestions.add(value);
            }
          }
          break;
          
        case CrossLinkStepType.targetSlot:
          // Step 4: Show target slots
          final List<String> targetSlots = _getTopicBasedSourceSlots();
          final String filterText = _extractFilterTextAfterArrow(crossLinkValue);
          
          for (final String slot in targetSlots) {
            if (filterText.isEmpty || slot.toLowerCase().contains(filterText.toLowerCase())) {
              // Don't suggest if it exactly matches what's already typed
              if (slot.toLowerCase() != filterText.toLowerCase()) {
                suggestions.add(slot);
              }
            }
          }
          break;
          
        case CrossLinkStepType.targetCommand:
          // Step 5: Show target commands
          final String targetSlot = _extractTargetSlotFromCrossLink(crossLinkValue);
          final List<String> commands = _getTargetCommandsForSlot(targetSlot);
          final String currentCommand = _extractCurrentCommandFromCrossLink(crossLinkValue);
          
          for (final String command in commands) {
            if (command.isNotEmpty) {
              // Don't suggest if it exactly matches what's already typed
              if (command.toLowerCase() != currentCommand.toLowerCase()) {
                suggestions.add(command);
              }
            }
          }
          break;
          
        case CrossLinkStepType.targetValue:
          // Step 6: Show target values (topic variables from target slot)
          final String targetSlot = _extractTargetSlotFromCrossLink(crossLinkValue);
          final List<String> topicValues = _getTopicValuesFromSlotSilent(targetSlot);
          final String currentTargetValue = _extractCurrentTargetValueFromCrossLink(crossLinkValue);
          
          for (final String value in topicValues) {
            // Don't suggest if it exactly matches what's already typed
            if (value.toLowerCase() != currentTargetValue.toLowerCase()) {
              suggestions.add(value);
            }
          }
          break;
      }
    }
    
    return suggestions;
  }

  /// Parse cross link step to determine current step type
  CrossLinkStepType _parseCrossLinkStep(String crossLinkValue, {bool logEnabled = true}) {
    if (logEnabled) {
      _log('DEBUG: _parseCrossLinkStep called with: "$crossLinkValue"');
    }
    
    if (crossLinkValue.isEmpty) {
      if (logEnabled) {
        _log('DEBUG: Empty cross link value, returning sourceSlot');
      }
      return CrossLinkStepType.sourceSlot;
    }
    
    // Check if we have source slot and looking for source report
    if (crossLinkValue.contains('/') && !crossLinkValue.contains('->')) {
      if (logEnabled) {
        _log('DEBUG: Found / without ->, returning sourceReport');
      }
      return CrossLinkStepType.sourceReport;
    }
    
    // Check if user just typed "/" after source slot - trigger source report selection
    if (crossLinkValue.endsWith('/')) {
      // Check if we're in the source part (before ->) or target part (after ->)
      if (crossLinkValue.contains('->')) {
        if (logEnabled) {
          _log('DEBUG: Ends with / after ->, returning targetCommand - TRIGGERED BY / TYPING');
        }
        return CrossLinkStepType.targetCommand;
      } else {
        if (logEnabled) {
          _log('DEBUG: Ends with / before ->, returning sourceReport - TRIGGERED BY / TYPING');
        }
        return CrossLinkStepType.sourceReport;
      }
    }
    
    // Check if we have source part and looking for target slot
    if (crossLinkValue.contains('->')) {
      final List<String> parts = crossLinkValue.split('->');
      if (parts.length == 1) {
        return CrossLinkStepType.targetSlot;
      } else if (parts.length == 2) {
        final String targetPart = parts[1];
        if (targetPart.isEmpty) {
          return CrossLinkStepType.targetSlot;
        } else if (!targetPart.contains('/')) {
          return CrossLinkStepType.targetCommand;
        } else {
          return CrossLinkStepType.targetValue;
        }
      }
    }
    
    // Check if we have source slot and source report, looking for source value
    if (crossLinkValue.contains('/')) {
      final List<String> sourceParts = crossLinkValue.split('/');
      if (sourceParts.length == 2 && sourceParts[1].isNotEmpty && !sourceParts[1].contains('->')) {
        return CrossLinkStepType.sourceValue;
      }
    }
    
    return CrossLinkStepType.sourceSlot;
  }

  /// Extract source slot from cross link value
  String _extractSourceSlotFromCrossLink(String crossLinkValue) {
    if (crossLinkValue.contains('/')) {
      return crossLinkValue.split('/')[0];
    } else if (crossLinkValue.contains('->')) {
      return crossLinkValue.split('->')[0].split('/')[0];
    }
    return crossLinkValue;
  }

  /// Extract target slot from cross link value
  String _extractTargetSlotFromCrossLink(String crossLinkValue) {
    if (crossLinkValue.contains('->')) {
      final List<String> parts = crossLinkValue.split('->');
      if (parts.length >= 2) {
        final String targetPart = parts[1];
        if (targetPart.contains('/')) {
          return targetPart.split('/')[0];
        }
        return targetPart;
      }
    }
    return '';
  }

  /// Extract filter text after slash (for source report filtering)
  String _extractFilterTextAfterSlash(String crossLinkValue) {
    if (crossLinkValue.contains('/')) {
      final List<String> parts = crossLinkValue.split('/');
      if (parts.length >= 2) {
        return parts[1];
      }
    }
    return '';
  }

  /// Extract filter text after arrow (for target slot filtering)
  String _extractFilterTextAfterArrow(String crossLinkValue) {
    if (crossLinkValue.contains('->')) {
      final List<String> parts = crossLinkValue.split('->');
      if (parts.length >= 2) {
        return parts[1];
      }
    }
    return '';
  }

  /// Extract current value from cross link (for source value filtering)
  String _extractCurrentValueFromCrossLink(String crossLinkValue) {
    if (crossLinkValue.contains(':')) {
      final List<String> parts = crossLinkValue.split(':');
      if (parts.length >= 2) {
        return parts[1];
      }
    }
    return '';
  }

  /// Extract current command from cross link (for target command filtering)
  String _extractCurrentCommandFromCrossLink(String crossLinkValue) {
    if (crossLinkValue.contains('->')) {
      final List<String> parts = crossLinkValue.split('->');
      if (parts.length >= 2) {
        final String targetPart = parts[1];
        if (targetPart.contains('/')) {
          final List<String> targetParts = targetPart.split('/');
          if (targetParts.length >= 2) {
            return targetParts[1];
          }
        }
        return targetPart;
      }
    }
    return '';
  }

  /// Extract current target value from cross link (for target value filtering)
  String _extractCurrentTargetValueFromCrossLink(String crossLinkValue) {
    if (crossLinkValue.contains('->')) {
      final List<String> parts = crossLinkValue.split('->');
      if (parts.length >= 2) {
        final String targetPart = parts[1];
        if (targetPart.contains('=')) {
          final List<String> targetParts = targetPart.split('=');
          if (targetParts.length >= 2) {
            return targetParts[1];
          }
        }
      }
    }
    return '';
  }

  /// Get report topics from manifest.json for the current mode
  List<String> _getReportTopicsForCurrentMode() {
    final List<String> reportTopics = <String>[];
    
    // Add empty string as first option
    reportTopics.add('');
    
    try {
      if (_manifestData.isEmpty) {
        _log('DEBUG: Manifest data is empty');
        return reportTopics;
      }
      
      // Get the current chapter from the text editor context
      final String? currentChapter = _getCurrentChapterFromTextEditor();
      _log('DEBUG: Current chapter from text editor: "$currentChapter"');
      if (currentChapter == null) {
        _log('DEBUG: No current chapter found');
        return reportTopics;
      }
      
      // Get the mode for the current chapter from text editor
      final String? modeValue = _parsedConfig[currentChapter]?['mode'];
      _log('DEBUG: Mode value for chapter "$currentChapter": "$modeValue"');
      if (modeValue == null || modeValue.isEmpty) {
        _log('DEBUG: No mode value found for current chapter');
        return reportTopics;
      }
      
      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        _log('DEBUG: Found ${modesArray.length} modes in manifest');
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            _log('DEBUG: Checking mode: "$modeName" against "$modeValue"');
            
            if (modeName == modeValue && modeItem['reports'] is List) {
              final List<dynamic> reportsArray = modeItem['reports'] as List<dynamic>;
              _log('DEBUG: Found ${reportsArray.length} reports for mode "$modeName"');
              
              for (final dynamic report in reportsArray) {
                if (report is Map<String, dynamic>) {
                  final String? topic = report['topic']?.toString();
                  if (topic != null && topic.isNotEmpty) {
                    reportTopics.add(topic);
                    _log('DEBUG: Added report topic: "$topic"');
                  }
                }
              }
              _log('DEBUG: Total report topics found: ${reportTopics.length}');
              break; // Found the mode, no need to continue
            }
          }
        }
      } else {
        _log('DEBUG: No modes array found in manifest data');
      }
    } catch (e) {
      _log('DEBUG: Error in _getReportTopicsForCurrentMode: $e');
    }
    
    return reportTopics;
  }

  /// Get report topics from manifest.json for a specific source slot's mode
  List<String> _getReportTopicsForSourceSlot(String sourceSlot) {
    final List<String> reportTopics = <String>[];
    
    // Add empty string as first option
    reportTopics.add('');
    
    try {
      if (_manifestData.isEmpty) {
        _log('DEBUG: Manifest data is empty');
        return reportTopics;
      }
      
      _log('DEBUG: Getting reports for source slot: "$sourceSlot"');
      
      // Search for the source slot in mode options where name="topic"
      String? sourceSlotMode;
      _log('DEBUG: Searching in mode options for topic "$sourceSlot"');
      
      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            if (modeItem['options'] is List) {
              final List<dynamic> optionsArray = modeItem['options'] as List<dynamic>;
              
              for (final dynamic option in optionsArray) {
                if (option is Map<String, dynamic>) {
                  final String? optionName = option['name']?.toString();
                  final String? valueDefault = option['valueDefault']?.toString();
                  
                  // Check both "player_0" and "/player_0" formats
                  if (optionName == 'topic' && 
                      (valueDefault == sourceSlot || valueDefault == '/$sourceSlot')) {
                    sourceSlotMode = modeName;
                    _log('DEBUG: Found topic "$sourceSlot" in mode "$modeName" with valueDefault "$valueDefault"');
                    break;
                  }
                }
              }
              if (sourceSlotMode != null) break;
            }
          }
        }
      }
      
      _log('DEBUG: Mode for source slot "$sourceSlot": "$sourceSlotMode"');
      
      if (sourceSlotMode == null || sourceSlotMode.isEmpty) {
        _log('DEBUG: No mode found for source slot "$sourceSlot"');
        return reportTopics;
      }
      
      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        _log('DEBUG: Found ${modesArray.length} modes in manifest');
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            _log('DEBUG: Checking mode: "$modeName" against source slot mode "$sourceSlotMode"');
            
            if (modeName == sourceSlotMode && modeItem['reports'] is List) {
              final List<dynamic> reportsArray = modeItem['reports'] as List<dynamic>;
              _log('DEBUG: Found ${reportsArray.length} reports for source slot mode "$modeName"');
              
              for (final dynamic report in reportsArray) {
                if (report is Map<String, dynamic>) {
                  final String? topic = report['topic']?.toString();
                  if (topic != null && topic.isNotEmpty) {
                    reportTopics.add(topic);
                    _log('DEBUG: Added report topic for source slot: "$topic"');
                  }
                }
              }
              _log('DEBUG: Total report topics found for source slot: ${reportTopics.length}');
              break; // Found the mode, no need to continue
            }
          }
        }
      } else {
        _log('DEBUG: No modes array found in manifest data');
      }
    } catch (e) {
      _log('DEBUG: Error in _getReportTopicsForSourceSlot: $e');
    }
    
    return reportTopics;
  }

  /// Get commands from manifest.json for a specific target slot
  List<String> _getTargetCommandsForSlot(String? targetSlot) {
    final List<String> commands = <String>[];
    
    // Add empty string as first option
    commands.add('');
    
    try {
      if (_manifestData.isEmpty || targetSlot == null || targetSlot.isEmpty) {
        return commands;
      }
      
      // Extract the actual slot name from the complex target slot format
      final String actualSlot = _extractActualSlotFromComplex(targetSlot);
      
      // Get the mode for the target slot
      final String? modeValue = _parsedConfig[actualSlot]?['mode'];
      if (modeValue == null || modeValue.isEmpty) {
        return commands;
      }
      
      if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
        final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
        
        for (final dynamic modeItem in modesArray) {
          if (modeItem is Map<String, dynamic>) {
            final String? modeName = modeItem['mode']?.toString();
            
            if (modeName == modeValue && modeItem['commands'] is List) {
              final List<dynamic> commandsArray = modeItem['commands'] as List<dynamic>;
              
              for (final dynamic command in commandsArray) {
                if (command is Map<String, dynamic>) {
                  final String? commandName = command['command']?.toString();
                  if (commandName != null && commandName.isNotEmpty) {
                    commands.add(commandName);
                  }
                }
              }
              break; // Found the mode, no need to continue
            }
          }
        }
      }
    } catch (e) {
      // Silent error handling
    }
    
    return commands;
  }

  void _addCrossLinkRule(String sourceSlot, String? sourceReport, String sourceValue, String targetSlot, String? targetCommand, String ruleValue) {
    if (_selectedChapter == null) {
      return;
    }

    // Create rule with new structure: sourceSlot[/sourceReport]:sourceValue->targetSlot[/targetCommand]:targetValue
    // Use complex slot names (e.g., player_0) instead of simple slot names (e.g., SLOT_0)
    // Build source part: sourceSlot[/sourceReport]:sourceValue
    String sourcePart = sourceSlot;
    if (sourceReport != null && sourceReport.isNotEmpty) {
      sourcePart = '$sourceSlot/$sourceReport';
    }
    sourcePart = '$sourcePart:${sourceValue.isNotEmpty ? sourceValue : ''}';
    
    // Build target part: targetSlot[/targetCommand]:targetValue
    String targetPart = targetSlot;
    if (targetCommand != null && targetCommand.isNotEmpty) {
      targetPart = '$targetSlot/$targetCommand';
    }
    targetPart = '$targetPart:${ruleValue.isNotEmpty ? ruleValue : ''}';
    
    // Combine source and target parts
    String rule = '$sourcePart->$targetPart';
    
    final TextEditingController? crossLinkController = _configControllers['cross_link'];
    final String currentCrossLink = crossLinkController?.text ?? '';
    final String newCrossLink = currentCrossLink.isEmpty ? rule : '$currentCrossLink,$rule';
    
    if (crossLinkController != null) {
      crossLinkController.text = newCrossLink;
    } else {
      _parsedConfig[_selectedChapter!]!['cross_link'] = newCrossLink;
      _refreshDesignDirtyState();
    }
    
    _log('Added cross link rule: $rule (from complex source: $sourceSlot, target: $targetSlot${sourceReport != null ? ', report: $sourceReport' : ''}${sourceValue.isNotEmpty ? ', source value: $sourceValue' : ''}${targetCommand != null && targetCommand.isNotEmpty ? ', command: $targetCommand' : ''})');
  }

  /// Extract actual slot name from complex format (e.g., "sensor_data_1" -> "SLOT_1")
  String _extractActualSlotFromComplex(String complexSlot) {
    // If it's already a simple slot name, return as-is
    if (complexSlot.startsWith('SLOT_')) {
      return complexSlot;
    }
    
    // Extract slot number from the end of the complex slot name
    final RegExp slotNumberRegex = RegExp(r'_(\d+)$');
    final Match? match = slotNumberRegex.firstMatch(complexSlot);
    
    if (match != null) {
      final String slotNumber = match.group(1)!;
      return 'SLOT_$slotNumber';
    }
    
    // Fallback: return the original if we can't parse it
    return complexSlot;
  }

  Widget _buildValueInput(String keyName, TextEditingController controller) {
    final Map<String, dynamic>? keyInfo = _getKeyInfo(_selectedChapter!, keyName);
    if (keyInfo == null) return const SizedBox.shrink();

    // Check if this key has spec type
    if (keyInfo['spec'] != null) {
      final String specType = keyInfo['spec'].toString();
      if (specType == 'slot_mode') {
        return _buildSlotModeDropdown(controller);
      }
    }
    
    // Check if this key has enum values
    if (keyInfo['enum'] != null && keyInfo['enum'] is List) {
      final List<dynamic> enumValues = keyInfo['enum'] as List<dynamic>;
      return DropdownButtonFormField<String>(
        value: controller.text.isNotEmpty ? controller.text : null,
        decoration: const InputDecoration(
          labelText: 'Value',
          border: OutlineInputBorder(),
        ),
        items: enumValues.map((dynamic value) {
          return DropdownMenuItem<String>(
            value: value.toString(),
            child: Text(value.toString()),
          );
        }).toList(),
        onChanged: (String? newValue) {
          if (newValue != null) {
            controller.text = newValue;
          }
        },
      );
    } else {
      // Regular text input
      return TextField(
        controller: controller,
        decoration: const InputDecoration(
          labelText: 'Value',
          border: OutlineInputBorder(),
        ),
      );
    }
  }

  Widget _buildSlotModeDropdown(TextEditingController controller) {
    final List<Map<String, dynamic>> modeOptions = _getModeOptions();
    
    // Remove duplicates based on mode name
    final Map<String, Map<String, dynamic>> uniqueModes = <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> mode in modeOptions) {
      final String modeName = mode['mode']?.toString() ?? '';
      if (modeName.isNotEmpty && !uniqueModes.containsKey(modeName)) {
        uniqueModes[modeName] = mode;
      }
    }
    
    final List<Map<String, dynamic>> uniqueModeList = uniqueModes.values.toList();
    
    return DropdownButtonFormField<String>(
      value: controller.text.isNotEmpty ? controller.text : null,
      decoration: const InputDecoration(
        labelText: 'Mode',
        border: OutlineInputBorder(),
      ),
      items: uniqueModeList.map((Map<String, dynamic> mode) {
        final String modeName = mode['mode']?.toString() ?? '';
        final String description = mode['description']?.toString() ?? '';
        final String displayText = description.isNotEmpty ? '$modeName - $description' : modeName;
        
        return DropdownMenuItem<String>(
          value: modeName,
          child: Text(displayText),
        );
      }).toList(),
      onChanged: (String? newValue) {
        if (newValue != null) {
          // Store only the mode name, not the description
          controller.text = newValue;
        }
      },
      selectedItemBuilder: (BuildContext context) {
        // Show only mode name in the selected value, even though dropdown items have descriptions
        return uniqueModeList.map((Map<String, dynamic> mode) {
          final String modeName = mode['mode']?.toString() ?? '';
          return Text(modeName);
        }).toList();
      },
    );
  }

  List<Map<String, dynamic>> _getModeOptions() {
    final List<Map<String, dynamic>> modes = <Map<String, dynamic>>[];
    
    if (_manifestData.containsKey('modes') && _manifestData['modes'] is List) {
      final List<dynamic> modesArray = _manifestData['modes'] as List<dynamic>;
      for (final dynamic modeItem in modesArray) {
        if (modeItem is Map<String, dynamic>) {
          modes.add(modeItem);
        }
      }
    }
    
    _log('Found ${modes.length} mode options for slot_mode');
    return modes;
  }

  void _addNewKeyValue(String keyName, String value) {
    if (_selectedChapter == null || !_parsedConfig.containsKey(_selectedChapter)) {
      return;
    }

    _parsedConfig[_selectedChapter!]![keyName] = value;

    setState(() {
      _updateConfigControllers();
    });
    _log('Added new key: $keyName with value: $value');
    _refreshDesignDirtyState();
  }

  void _deleteKeyValue(String key) {
    if (_selectedChapter == null || !_parsedConfig.containsKey(_selectedChapter)) {
      return;
    }

    // Remove from parsed config
    _parsedConfig[_selectedChapter!]!.remove(key);
    
    setState(() {
      _updateConfigControllers();
    });
    _log('Deleted key: $key');
    _refreshDesignDirtyState();
  }

  Future<void> _saveConfigToFile() async {
    await _saveConfigToFileWithResult();
  }

  /// Save config to file and return true if successful
  Future<bool> _saveConfigToFileWithResult() async {
    if (_cachedConfigPath == null) {
      _log('No config file path available for saving');
      return false;
    }
    
    try {
      // Rebuild config file content
      final String configContent = _buildConfigContentFromParsedConfig();
      
      // Check if this is an FTP path (for mDNS devices) or local path (for serial devices)
      if (_cachedConfigPath!.startsWith('ftp://')) {
        // Save to FTP server
        await _saveConfigToFtp(configContent);
        return true;
      } else {
        // Save to local file
        await File(_cachedConfigPath!).writeAsString(configContent);
        _handleConfigPersisted(configContent);
        _log('Configuration saved to $_cachedConfigPath');
        return true;
      }
    } catch (e) {
      _log('Error saving configuration: $e');
      return false;
    }
  }

  /// Save configuration to FTP server
  Future<void> _saveConfigToFtp(String configContent) async {
    if (_selected == null || _selected!.kind != 'mDNS') {
      _log('FTP save: No mDNS device selected');
      return;
    }
    
    try {
      // Extract IP address from device identifier (format: "ip:port")
      final String deviceIp = _selected!.identifier.split(':')[0];
      
      _log('FTP: Connecting to $deviceIp:21 for save');
      
      // Create FTP connection
      final FTPConnect ftpConnect = FTPConnect(deviceIp, port: 21, user: 'anonymous', pass: '');
      final bool connected = await ftpConnect.connect();
      
      if (!connected) {
        _log('FTP: Failed to connect to $deviceIp:21 for save');
        return;
      }
      
      _log('FTP: Successfully connected for save');
      
      // Set transfer mode to passive for data transfers
      ftpConnect.transferMode = TransferMode.passive;
      _log('FTP: Passive mode enabled for save');
      
      // Write config content to temporary file with the correct remote filename
      final File tempFile = File('./config.ini');
      await tempFile.writeAsString(configContent);
      
      // Upload to FTP server (remote filename will be 'config.ini' based on local filename)
      final bool uploaded = await ftpConnect.uploadFile(tempFile);
      
      if (uploaded) {
        _handleConfigPersisted(configContent);
        _log('FTP: Configuration saved successfully');
      } else {
        _log('FTP: Failed to upload configuration');
      }
      
      // Clean up temporary file
      try {
        await tempFile.delete();
      } catch (_) {}
      
      // Disconnect from FTP server
      try {
        await ftpConnect.disconnect();
        _log('FTP: Disconnected after save');
      } catch (_) {}
      
    } catch (e) {
      _log('FTP: Error saving configuration: $e');
    }
  }
}


