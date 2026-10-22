import 'package:flutter/material.dart';
import 'package:marten/features/log/data/log_path_resolver.dart';

class ProfilingReportPage extends StatefulWidget {
  const ProfilingReportPage({super.key, required this.resolver});
  final LogPathResolver resolver;

  @override
  State<ProfilingReportPage> createState() => _ProfilingReportPageState();
}

class _ProfilingReportPageState extends State<ProfilingReportPage> {
  late Future<String> report = widget.resolver.readProfilingReport();

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    return Scaffold(
      appBar: AppBar(
        title: Text(ru ? 'Профиль нагрузки' : 'Load profile'),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              report = widget.resolver.readProfilingReport();
            }),
            icon: const Icon(Icons.refresh),
            tooltip: ru ? 'Обновить отчёт' : 'Refresh report',
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: report,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) {
            return Center(child: Text(ru ? 'Отчёт пока недоступен' : 'Report is not available yet'));
          }
          final lines = (snapshot.data ?? '').split('\n');
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: lines.length + 1,
            itemBuilder: (context, index) => index == 0
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      ru
                          ? 'Сбор идёт постоянно и автоматически. Отчёт показывает весь измеренный CPU, отдельно работу диагностики и горячие функции. Для отправки одного полного отчёта нажмите «Поделиться» на экране логов. Проценты CPU относятся к одному ядру процессора.'
                          : 'Collection runs continuously and automatically. The report shows all measured CPU, diagnostic work separately and hot functions. Use Share on the logs screen to send one complete report. CPU percentages refer to one processor core.',
                    ),
                  )
                : SelectableText(lines[index - 1], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          );
        },
      ),
    );
  }
}
