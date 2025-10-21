import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize DB early to avoid race conditions / blank screens
  await TasksDB.instance.database;
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('isDarkMode') ?? false;
  runApp(MyApp(isDarkMode: isDark));
}

// -------------------- Models --------------------
enum Priority { low, medium, high }

extension PriorityExt on Priority {
  String get label {
    switch (this) {
      case Priority.high:
        return 'High';
      case Priority.medium:
        return 'Medium';
      case Priority.low:
      default:
        return 'Low';
    }
  }

  int get value {
    switch (this) {
      case Priority.high:
        return 3;
      case Priority.medium:
        return 2;
      case Priority.low:
      default:
        return 1;
    }
  }

  static Priority fromInt(int v) {
    switch (v) {
      case 3:
        return Priority.high;
      case 2:
        return Priority.medium;
      case 1:
      default:
        return Priority.low;
    }
  }
}

class Task {
  int? id;
  String name;
  bool done;
  Priority priority;
  int createdAt;

  Task({
    this.id,
    required this.name,
    this.done = false,
    this.priority = Priority.medium,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'done': done ? 1 : 0,
      'priority': priority.value,
      'createdAt': createdAt,
    };
  }

  static Task fromMap(Map<String, dynamic> m) {
    return Task(
      id: m['id'] as int?,
      name: m['name'] as String,
      done: (m['done'] as int) == 1,
      priority: PriorityExt.fromInt(m['priority'] as int),
      createdAt: m['createdAt'] as int,
    );
  }
}

// -------------------- Database Helper (sqflite) --------------------
class TasksDB {
  static final TasksDB instance = TasksDB._init();
  static Database? _db;
  TasksDB._init();

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB('cw3_tasks.db');
    return _db!;
  }

  Future<Database> _initDB(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, fileName);
    // For development: uncomment to reset DB
    // await deleteDatabase(path);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        done INTEGER NOT NULL,
        priority INTEGER NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
  }

  Future<Task> create(Task t) async {
    final db = await database;
    t.id = await db.insert('tasks', t.toMap());
    return t;
  }

  Future<List<Task>> readAll() async {
    final db = await database;
    // order: priority desc (3 high -> 1 low), then createdAt asc
    final res =
        await db.query('tasks', orderBy: 'priority DESC, createdAt ASC');
    return res.map((e) => Task.fromMap(e)).toList();
  }

  Future<int> update(Task t) async {
    final db = await database;
    return db.update('tasks', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
  }

  Future<int> delete(int id) async {
    final db = await database;
    return db.delete('tasks', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteAll() async {
    final db = await database;
    return db.delete('tasks');
  }
}

// -------------------- App --------------------
class MyApp extends StatefulWidget {
  final bool isDarkMode;
  const MyApp({super.key, required this.isDarkMode});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.isDarkMode;
  }

  Future<void> _toggleTheme(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _isDarkMode = v);
    await prefs.setBool('isDarkMode', v);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CW-03 Task Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: TaskListScreen(
        isDark: _isDarkMode,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

// -------------------- TaskListScreen (StatefulWidget) --------------------
class TaskListScreen extends StatefulWidget {
  final bool isDark;
  final Future<void> Function(bool) onToggleTheme;

  const TaskListScreen(
      {super.key, required this.isDark, required this.onToggleTheme});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  final TextEditingController _ctrl = TextEditingController();
  Priority _selectedPriority = Priority.medium;
  bool _loading = true;
  List<Task> _tasks = [];

  @override
  void initState() {
    super.initState();
    _refreshTasks();
  }

  Future<void> _refreshTasks() async {
    setState(() => _loading = true);
    try {
      final data = await TasksDB.instance.readAll();
      setState(() {
        _tasks = data;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('Error loading tasks: $e\n$st');
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error loading tasks: $e')));
      }
    }
  }

  Future<void> _addTask() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a task name')));
      return;
    }
    final t = Task(name: name, priority: _selectedPriority);
    await TasksDB.instance.create(t);
    _ctrl.clear();
    // reload and keep sorted by priority desc inside DB query
    await _refreshTasks();
  }

  Future<void> _toggleDone(Task t) async {
    t.done = !t.done;
    await TasksDB.instance.update(t);
    await _refreshTasks();
  }

  Future<void> _deleteTask(Task t) async {
    if (t.id == null) return;
    await TasksDB.instance.delete(t.id!);
    await _refreshTasks();
  }

  Future<void> _editTask(Task t) async {
    final res = await showDialog<_EditResult?>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: t.name);
        Priority pr = t.priority;
        return AlertDialog(
          title: const Text('Edit Task'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(labelText: 'Task name')),
              const SizedBox(height: 12),
              DropdownButtonFormField<Priority>(
                value: pr,
                items: Priority.values
                    .map(
                        (p) => DropdownMenuItem(value: p, child: Text(p.label)))
                    .toList(),
                onChanged: (v) => pr = v ?? pr,
                decoration: const InputDecoration(labelText: 'Priority'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () {
                  final text = ctrl.text.trim();
                  if (text.isEmpty) return;
                  Navigator.pop(ctx, _EditResult(text, pr));
                },
                child: const Text('Save')),
          ],
        );
      },
    );

    if (res != null) {
      t.name = res.name;
      t.priority = res.priority;
      await TasksDB.instance.update(t);
      await _refreshTasks();
    }
  }

  Future<void> _deleteAllConfirmed() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all tasks?'),
        content: const Text('This will permanently remove all tasks.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await TasksDB.instance.deleteAll();
      await _refreshTasks();
    }
  }

  Widget _priorityChip(Priority p) {
    Color c;
    switch (p) {
      case Priority.high:
        c = Colors.redAccent;
        break;
      case Priority.medium:
        c = Colors.orange;
        break;
      case Priority.low:
      default:
        c = Colors.green;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(p.label, style: TextStyle(color: c, fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TaskList (CW-03)'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshTasks,
          ),
          IconButton(
            tooltip: 'Delete all',
            icon: const Icon(Icons.delete_forever),
            onPressed: _deleteAllConfirmed,
          ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: widget.isDark
                ? const Icon(Icons.light_mode)
                : const Icon(Icons.dark_mode),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              final newVal = !(prefs.getBool('isDarkMode') ?? false);
              await prefs.setBool('isDarkMode', newVal);
              // call parent to toggle theme (MyApp listens to prefs at start; we force rebuild by restarting root)
              // simpler approach: use setState + re-run MyApp is not trivial; instead show message and instruct to restart
              // but requirement asks for theme toggle persisted; we call Navigator.pop and rebuild via a small workaround:
              // (Simpler approach: directly use setState to change theme at app-level in MyApp; here we use a different approach:)
              // For simplicity, rebuild by popping and pushing MaterialApp (not ideal but works for assignment).
              // However we'll just call widget.onToggleTheme to update top-level theme state (declared as Future<void> Function(bool) in MyApp)
              await widget.onToggleTheme(newVal);
              setState(() {});
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            decoration: const InputDecoration(
                              labelText: 'Task name',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _addTask(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<Priority>(
                          value: _selectedPriority,
                          items: Priority.values
                              .map((p) => DropdownMenuItem(
                                  value: p, child: Text(p.label)))
                              .toList(),
                          onChanged: (v) => setState(
                              () => _selectedPriority = v ?? Priority.medium),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _addTask,
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _tasks.isEmpty
                          ? const Center(
                              child:
                                  Text('No tasks yet. Tap Add to create one.'))
                          : RefreshIndicator(
                              onRefresh: _refreshTasks,
                              child: ListView.builder(
                                itemCount: _tasks.length,
                                itemBuilder: (context, index) {
                                  final t = _tasks[index];
                                  return Card(
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 6),
                                    child: ListTile(
                                      leading: Checkbox(
                                        value: t.done,
                                        onChanged: (_) => _toggleDone(t),
                                      ),
                                      title: Text(
                                        t.name,
                                        style: TextStyle(
                                          decoration: t.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                      ),
                                      subtitle: Row(
                                        children: [
                                          _priorityChip(t.priority),
                                          const SizedBox(width: 8),
                                          Text(
                                            DateTime.fromMillisecondsSinceEpoch(
                                                    t.createdAt)
                                                .toLocal()
                                                .toString()
                                                .split('.')
                                                .first,
                                            style:
                                                const TextStyle(fontSize: 12),
                                          ),
                                        ],
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        onSelected: (v) {
                                          if (v == 'edit') _editTask(t);
                                          if (v == 'delete') _deleteTask(t);
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                              value: 'edit',
                                              child: Text('Edit')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete')),
                                        ],
                                      ),
                                    ),
                                  );
                                },
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

class _EditResult {
  final String name;
  final Priority priority;
  _EditResult(this.name, this.priority);
}