/// FRC WPILib/REVLib code snippet generator.
///
/// Generates ready-to-use Java, Python, and C++ code snippets that configure
/// a REV SPARK motor controller with the identified feedforward and PID gains,
/// conversion factors, ramp rate, and inversion setting.
library;

import '../mechanisms/mechanism.dart';
import 'test_data.dart';

/// A complete set of generated code snippets for all three languages.
class CodeSnippets {
  final String java;
  final String python;
  final String cpp;

  const CodeSnippets({
    required this.java,
    required this.python,
    required this.cpp,
  });
}

/// Generates FRC WPILib/REVLib code snippets from identified system parameters.
class CodeSnippetExporter {
  /// Generate code snippets for all supported languages.
  ///
  /// [config] — mechanism configuration (conversion factors, inverted, etc.)
  /// [ff] — identified feedforward gains (kS, kV, kA, kG)
  /// [velocityPid] — auto-tuned velocity PID gains (may be null)
  /// [positionPid] — auto-tuned position PID gains (may be null)
  /// [canId] — CAN device ID (default 1)
  /// [openLoopRampRate] — open-loop ramp rate in seconds (default 0.0)
  /// [closedLoopRampRate] — closed-loop ramp rate in seconds (default 0.0)
  static CodeSnippets generate({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    int canId = 1,
    double openLoopRampRate = 0.0,
    double closedLoopRampRate = 0.0,
  }) {
    return CodeSnippets(
      java: _generateJava(
        config: config,
        ff: ff,
        velocityPid: velocityPid,
        positionPid: positionPid,
        canId: canId,
        openLoopRampRate: openLoopRampRate,
        closedLoopRampRate: closedLoopRampRate,
      ),
      python: _generatePython(
        config: config,
        ff: ff,
        velocityPid: velocityPid,
        positionPid: positionPid,
        canId: canId,
        openLoopRampRate: openLoopRampRate,
        closedLoopRampRate: closedLoopRampRate,
      ),
      cpp: _generateCpp(
        config: config,
        ff: ff,
        velocityPid: velocityPid,
        positionPid: positionPid,
        canId: canId,
        openLoopRampRate: openLoopRampRate,
        closedLoopRampRate: closedLoopRampRate,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _fmt(double v) => v.toStringAsFixed(6);

  static String _motorType(bool brushless) =>
      brushless ? 'kBrushless' : 'kBrushed';

  // ---------------------------------------------------------------------------
  // Java
  // ---------------------------------------------------------------------------

  static String _generateJava({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    required int canId,
    required double openLoopRampRate,
    required double closedLoopRampRate,
  }) {
    final motorType = _motorType(config.isBrushless);
    final inverted = config.motorInverted ? 'true' : 'false';
    final posConv = _fmt(config.positionConversionFactor);
    final velConv = _fmt(config.velocityConversionFactor);
    final olRamp = _fmt(openLoopRampRate);
    final clRamp = _fmt(closedLoopRampRate);
    final currentLimit = config.currentLimitAmps.toInt();

    final systemLabel = config.systemName.isNotEmpty
        ? config.systemName
        : config.type.displayName;

    final velP = velocityPid != null ? _fmt(velocityPid.kP) : '0.000000';
    final velI = velocityPid != null ? _fmt(velocityPid.kI) : '0.000000';
    final velD = velocityPid != null ? _fmt(velocityPid.kD) : '0.000000';
    final posP = positionPid != null ? _fmt(positionPid.kP) : '0.000000';
    final posI = positionPid != null ? _fmt(positionPid.kI) : '0.000000';
    final posD = positionPid != null ? _fmt(positionPid.kD) : '0.000000';

    final kS = _fmt(ff.kS);
    final kV = _fmt(ff.kV);
    final kA = _fmt(ff.kA);
    final kG = _fmt(ff.kG);
    final hasGravity = config.type.hasGravity;

    final gravityLine = hasGravity ? '\n                .kG($kG)' : '';

    // Velocity PID — Slot 0
    final velSlot = velocityPid != null ? '''

        // --- Velocity PID (Slot 0) ---
        config.closedLoop
                .feedbackSensor(FeedbackSensor.${config.feedbackSensor.javaName})
                .pid($velP, $velI, $velD);
        config.closedLoop.feedForward
                .kS($kS)
                .kV($kV)
                .kA($kA)$gravityLine;''' : '';

    // Position PID — Slot 1
    final posSlot = positionPid != null ? '''

        // --- Position PID (Slot 1) ---
        config.closedLoop.slot1
                .pid($posP, $posI, $posD);
        config.closedLoop.slot1.feedForward
                .kS($kS)
                .kV($kV)
                .kA($kA)$gravityLine;''' : '';

    // Soft limits
    final javaSoftLimits = config.hasSoftLimits ? '''

        // --- Soft limits ---
        config.softLimit
                .forwardSoftLimitEnabled(true)
                .forwardSoftLimit(${_fmt(config.forwardSoftLimit!)})
                .reverseSoftLimitEnabled(true)
                .reverseSoftLimit(${_fmt(config.reverseSoftLimit!)});''' : '';

    final className = _javaClassName(systemLabel);

    return '''// $systemLabel — Generated by Crumboe's (unofficial) REV System Identification
// REVLib 2025 (Java)
// CAN ID: $canId  |  Motor: ${config.isBrushless ? "Brushless" : "Brushed"}
// Position units: ${config.positionUnit}  |  Velocity units: ${config.velocityUnit}

import com.revrobotics.spark.SparkMax;
import com.revrobotics.spark.SparkBase.ControlType;
import com.revrobotics.spark.SparkBase.PersistMode;
import com.revrobotics.spark.SparkBase.ResetMode;
import com.revrobotics.spark.ClosedLoopSlot;
import com.revrobotics.spark.SparkLowLevel.MotorType;
import com.revrobotics.spark.config.SparkMaxConfig;
import com.revrobotics.spark.config.ClosedLoopConfig.FeedbackSensor;
import com.revrobotics.spark.config.SparkBaseConfig.IdleMode;

public class $className {

    private final SparkMax motor =
            new SparkMax($canId, MotorType.$motorType);

    public $className() {
        SparkMaxConfig config = new SparkMaxConfig();

        // --- Motor settings ---
        config.inverted($inverted)
              .idleMode(IdleMode.kBrake)
              .smartCurrentLimit($currentLimit);

        // --- Ramp rates (seconds; 0.0 = disabled) ---
        config.openLoopRampRate($olRamp);
        config.closedLoopRampRate($clRamp);

        // --- Encoder conversion factors ---
        // positionConversionFactor: rotations → ${config.positionUnit}
        // velocityConversionFactor: RPM → ${config.velocityUnit}
        config.encoder
                .positionConversionFactor($posConv)
                .velocityConversionFactor($velConv);
$velSlot$posSlot$javaSoftLimits

        // --- Apply and persist ---
        motor.configure(
                config,
                ResetMode.kResetSafeParameters,
                PersistMode.kPersistParameters);
    }

    /** Velocity closed-loop (Slot 0). setpoint in ${config.velocityUnit} */
    public void setVelocity(double setpoint) {
        motor.getClosedLoopController().setReference(
                setpoint,
                ControlType.kVelocity,
                ClosedLoopSlot.kSlot0);
    }

    /** Position closed-loop (Slot 1). setpoint in ${config.positionUnit} */
    public void setPosition(double setpoint) {
        motor.getClosedLoopController().setReference(
                setpoint,
                ControlType.kPosition,
                ClosedLoopSlot.kSlot1);
    }
}''';
  }

  // ---------------------------------------------------------------------------
  // Python
  // ---------------------------------------------------------------------------

  static String _generatePython({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    required int canId,
    required double openLoopRampRate,
    required double closedLoopRampRate,
  }) {
    final motorType = config.isBrushless
        ? 'SparkLowLevel.MotorType.kBrushless'
        : 'SparkLowLevel.MotorType.kBrushed';
    final inverted = config.motorInverted ? 'True' : 'False';
    final posConv = _fmt(config.positionConversionFactor);
    final velConv = _fmt(config.velocityConversionFactor);
    final olRamp = _fmt(openLoopRampRate);
    final clRamp = _fmt(closedLoopRampRate);
    final currentLimit = config.currentLimitAmps.toInt();

    final systemLabel = config.systemName.isNotEmpty
        ? config.systemName
        : config.type.displayName;

    final velP = velocityPid != null ? _fmt(velocityPid.kP) : '0.000000';
    final velI = velocityPid != null ? _fmt(velocityPid.kI) : '0.000000';
    final velD = velocityPid != null ? _fmt(velocityPid.kD) : '0.000000';
    final posP = positionPid != null ? _fmt(positionPid.kP) : '0.000000';
    final posI = positionPid != null ? _fmt(positionPid.kI) : '0.000000';
    final posD = positionPid != null ? _fmt(positionPid.kD) : '0.000000';

    final kS = _fmt(ff.kS);
    final kV = _fmt(ff.kV);
    final kA = _fmt(ff.kA);
    final kG = _fmt(ff.kG);
    final hasGravity = config.type.hasGravity;

    final ffLines = StringBuffer()
      ..writeln('        config.closedLoop.feedForward.kS($kS)')
      ..writeln('        config.closedLoop.feedForward.kV($kV)')
      ..write('        config.closedLoop.feedForward.kA($kA)');
    if (hasGravity) ffLines.write('\n        config.closedLoop.feedForward.kG($kG)');

    final ffLinesSlot1 = StringBuffer()
      ..writeln('        config.closedLoop.slot1.feedForward.kS($kS)')
      ..writeln('        config.closedLoop.slot1.feedForward.kV($kV)')
      ..write('        config.closedLoop.slot1.feedForward.kA($kA)');
    if (hasGravity) {
      ffLinesSlot1.write('\n        config.closedLoop.slot1.feedForward.kG($kG)');
    }

    final velSection = velocityPid != null ? '''

        # --- Velocity PID (Slot 0) ---
        config.closedLoop.feedbackSensor(
            ClosedLoopConfig.FeedbackSensor.${config.feedbackSensor.pythonName})
        config.closedLoop.pid($velP, $velI, $velD)
$ffLines''' : '';

    final posSection = positionPid != null ? '''

        # --- Position PID (Slot 1) ---
        config.closedLoop.slot1.pid($posP, $posI, $posD)
$ffLinesSlot1''' : '';

    final pySoftLimits = config.hasSoftLimits ? '''

        # --- Soft limits ---
        config.softLimit.forwardSoftLimitEnabled(True)
        config.softLimit.forwardSoftLimit(${_fmt(config.forwardSoftLimit!)})
        config.softLimit.reverseSoftLimitEnabled(True)
        config.softLimit.reverseSoftLimit(${_fmt(config.reverseSoftLimit!)})''' : '';

    final className = _pyClassName(systemLabel);

    return '''# $systemLabel — Generated by Crumboe's (unofficial) REV System Identification
# REVLib 2025 (Python)
# CAN ID: $canId  |  Motor: ${config.isBrushless ? "Brushless" : "Brushed"}
# Position units: ${config.positionUnit}  |  Velocity units: ${config.velocityUnit}

from rev import (
    SparkMax, SparkMaxConfig, SparkBase, ClosedLoopSlot,
    SparkLowLevel, ClosedLoopConfig, SparkBaseConfig,
)


class $className:
    def __init__(self) -> None:
        self._motor = SparkMax($canId, $motorType)

        config = SparkMaxConfig()

        # --- Motor settings ---
        config.inverted($inverted)
        config.idleMode(SparkBaseConfig.IdleMode.kBrake)
        config.smartCurrentLimit($currentLimit)

        # --- Ramp rates (0.0 = disabled) ---
        config.openLoopRampRate($olRamp)
        config.closedLoopRampRate($clRamp)

        # --- Encoder conversion factors ---
        # positionConversionFactor: rotations → ${config.positionUnit}
        # velocityConversionFactor: RPM → ${config.velocityUnit}
        config.encoder.positionConversionFactor($posConv)
        config.encoder.velocityConversionFactor($velConv)
$velSection$posSection$pySoftLimits

        # --- Apply and persist ---
        self._motor.configure(
            config,
            SparkBase.ResetMode.kResetSafeParameters,
            SparkBase.PersistMode.kPersistParameters,
        )

    def set_velocity(self, setpoint: float) -> None:
        """Velocity closed-loop (Slot 0). setpoint in ${config.velocityUnit}"""
        self._motor.getClosedLoopController().setReference(
            setpoint,
            SparkMax.ControlType.kVelocity,
            ClosedLoopSlot.kSlot0,
        )

    def set_position(self, setpoint: float) -> None:
        """Position closed-loop (Slot 1). setpoint in ${config.positionUnit}"""
        self._motor.getClosedLoopController().setReference(
            setpoint,
            SparkMax.ControlType.kPosition,
            ClosedLoopSlot.kSlot1,
        )''';
  }

  // ---------------------------------------------------------------------------
  // C++
  // ---------------------------------------------------------------------------

  static String _generateCpp({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    required int canId,
    required double openLoopRampRate,
    required double closedLoopRampRate,
  }) {
    final motorType = config.isBrushless
        ? 'rev::spark::SparkLowLevel::MotorType::kBrushless'
        : 'rev::spark::SparkLowLevel::MotorType::kBrushed';
    final inverted = config.motorInverted ? 'true' : 'false';
    final posConv = _fmt(config.positionConversionFactor);
    final velConv = _fmt(config.velocityConversionFactor);
    final olRamp = _fmt(openLoopRampRate);
    final clRamp = _fmt(closedLoopRampRate);
    final currentLimit = config.currentLimitAmps.toInt();

    final systemLabel = config.systemName.isNotEmpty
        ? config.systemName
        : config.type.displayName;

    final velP = velocityPid != null ? _fmt(velocityPid.kP) : '0.000000';
    final velI = velocityPid != null ? _fmt(velocityPid.kI) : '0.000000';
    final velD = velocityPid != null ? _fmt(velocityPid.kD) : '0.000000';
    final posP = positionPid != null ? _fmt(positionPid.kP) : '0.000000';
    final posI = positionPid != null ? _fmt(positionPid.kI) : '0.000000';
    final posD = positionPid != null ? _fmt(positionPid.kD) : '0.000000';

    final kS = _fmt(ff.kS);
    final kV = _fmt(ff.kV);
    final kA = _fmt(ff.kA);
    final kG = _fmt(ff.kG);
    final hasGravity = config.type.hasGravity;

    final ffLines = StringBuffer()
      ..writeln('    config.closedLoop.feedForward.kS($kS);')
      ..writeln('    config.closedLoop.feedForward.kV($kV);')
      ..write('    config.closedLoop.feedForward.kA($kA);');
    if (hasGravity) ffLines.write('\n    config.closedLoop.feedForward.kG($kG);');

    final ffLinesSlot1 = StringBuffer()
      ..writeln('    config.closedLoop.slot1.feedForward.kS($kS);')
      ..writeln('    config.closedLoop.slot1.feedForward.kV($kV);')
      ..write('    config.closedLoop.slot1.feedForward.kA($kA);');
    if (hasGravity) {
      ffLinesSlot1.write('\n    config.closedLoop.slot1.feedForward.kG($kG);');
    }

    final velSection = velocityPid != null ? '''

    // --- Velocity PID (Slot 0) ---
    config.closedLoop
        .FeedbackSensor(rev::spark::ClosedLoopConfig::FeedbackSensor::${config.feedbackSensor.cppName})
        .Pid($velP, $velI, $velD);
$ffLines''' : '';

    final posSection = positionPid != null ? '''

    // --- Position PID (Slot 1) ---
    config.closedLoop.slot1.Pid($posP, $posI, $posD);
$ffLinesSlot1''' : '';

    final cppSoftLimits = config.hasSoftLimits ? '''

    // --- Soft limits ---
    config.softLimit.ForwardSoftLimitEnabled(true);
    config.softLimit.ForwardSoftLimit(${_fmt(config.forwardSoftLimit!)});
    config.softLimit.ReverseSoftLimitEnabled(true);
    config.softLimit.ReverseSoftLimit(${_fmt(config.reverseSoftLimit!)});''' : '';

    final className = _cppHeaderGuard(systemLabel);

    return '''// $systemLabel — Generated by Crumboe's (unofficial) REV System Identification
// REVLib 2025 (C++)
// CAN ID: $canId  |  Motor: ${config.isBrushless ? "Brushless" : "Brushed"}
// Position units: ${config.positionUnit}  |  Velocity units: ${config.velocityUnit}

#pragma once

#include <rev/SparkMax.h>
#include <rev/config/SparkMaxConfig.h>

class $className {
public:
    $className() {
        rev::spark::SparkMaxConfig config{};

        // --- Motor settings ---
        config.Inverted($inverted);
        config.SetIdleMode(rev::spark::SparkBaseConfig::IdleMode::kBrake);
        config.SmartCurrentLimit($currentLimit);

        // --- Ramp rates (0.0 = disabled) ---
        config.OpenLoopRampRate($olRamp);
        config.ClosedLoopRampRate($clRamp);

        // --- Encoder conversion factors ---
        // positionConversionFactor: rotations → ${config.positionUnit}
        // velocityConversionFactor: RPM → ${config.velocityUnit}
        config.encoder.PositionConversionFactor($posConv);
        config.encoder.VelocityConversionFactor($velConv);
$velSection$posSection$cppSoftLimits

        // --- Apply and persist ---
        m_motor.Configure(
            config,
            rev::spark::SparkBase::ResetMode::kResetSafeParameters,
            rev::spark::SparkBase::PersistMode::kPersistParameters);
    }

    /// Velocity closed-loop (Slot 0). setpoint in ${config.velocityUnit}
    void SetVelocity(double setpoint) {
        m_motor.GetClosedLoopController().SetReference(
            setpoint,
            rev::spark::SparkMax::ControlType::kVelocity,
            rev::spark::ClosedLoopSlot::kSlot0);
    }

    /// Position closed-loop (Slot 1). setpoint in ${config.positionUnit}
    void SetPosition(double setpoint) {
        m_motor.GetClosedLoopController().SetReference(
            setpoint,
            rev::spark::SparkMax::ControlType::kPosition,
            rev::spark::ClosedLoopSlot::kSlot1);
    }

private:
    rev::spark::SparkMax m_motor{$canId, $motorType};
};''';
  }

  // ---------------------------------------------------------------------------
  // Name sanitisers
  // ---------------------------------------------------------------------------

  /// Convert a free-form system name to a valid Java/C++ class identifier.
  static String _javaClassName(String name) {
    if (name.isEmpty) return 'MotorSubsystem';
    final parts = name
        .replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '')
        .trim()
        .split(RegExp(r'\s+'));
    return parts.map((p) {
      if (p.isEmpty) return '';
      return p[0].toUpperCase() + (p.length > 1 ? p.substring(1) : '');
    }).join();
  }

  /// Convert a free-form system name to a valid Python class identifier.
  static String _pyClassName(String name) => _javaClassName(name);

  /// Convert a free-form system name to a C++ header guard / class name.
  static String _cppHeaderGuard(String name) => _javaClassName(name);
}
