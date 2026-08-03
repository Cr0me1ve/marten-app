import 'package:fpdart/fpdart.dart';
import 'package:marten/core/utils/exception_handler.dart';
import 'package:marten/features/stats/model/stats_failure.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/utils/custom_loggers.dart';

abstract interface class StatsRepository {
  Stream<Either<StatsFailure, SystemInfo>> watchStats();
}

class StatsRepositoryImpl with ExceptionHandler, InfraLogger implements StatsRepository {
  StatsRepositoryImpl({required this.singbox});

  final MartenCoreService singbox;

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() {
    return singbox.watchStats().handleExceptions(StatsUnexpectedFailure.new);
  }
}
