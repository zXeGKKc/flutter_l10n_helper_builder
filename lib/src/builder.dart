import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:collection/collection.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class L10nConfig {
  final String arbDir;
  final String outputDir;
  final String templateArbFile;
  final String outputLocalizationFile;
  final String outputClass;
  final bool nullableGetter;
  final String? header;
  final bool? format;

  const L10nConfig({
    required this.arbDir,
    required this.outputDir,
    required this.templateArbFile,
    required this.outputLocalizationFile,
    required this.outputClass,
    required this.nullableGetter,
    this.header,
    this.format,
  });

  factory L10nConfig.fromYamlString(String yamlString) {
    final yamlMap = loadYaml(yamlString) as YamlMap;
    return L10nConfig(
      arbDir: yamlMap['arb-dir'] ?? 'lib/l10n',
      outputDir: yamlMap['output-dir'] ?? 'lib/l10n',
      templateArbFile: yamlMap['template-arb-file'] ?? 'en.arb',
      outputLocalizationFile:
          yamlMap['output-localization-file'] ?? 'app_localizations.dart',
      outputClass: yamlMap['output-class'] ?? 'AppLocalizations',
      nullableGetter: yamlMap['nullable-getter'] ?? false,
      header: yamlMap['header'],
      format: yamlMap['format'],
    );
  }
}

class L10nHelperBuilder extends Builder {
  @override
  final Map<String, List<String>> buildExtensions = {
    '.dart': ['.helper.dart'],
  };

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final l10n = File('l10n.yaml');
    if (!await l10n.exists()) return;

    final l10nString = await l10n.readAsString();
    final l10nConfig = L10nConfig.fromYamlString(l10nString);

    final targetPath = p.join(
      l10nConfig.outputDir,
      l10nConfig.outputLocalizationFile,
    );
    if (!p.equals(buildStep.inputId.path, targetPath)) return;

    final content = await buildStep.readAsString(buildStep.inputId);
    final result = _genContent(
      content,
      fileName: l10nConfig.outputLocalizationFile,
      className: l10nConfig.outputClass,
      nullable: l10nConfig.nullableGetter,
      header: l10nConfig.header,
    );

    if (result != null) {
      final outputId = buildStep.inputId.changeExtension('.helper.dart');
      await buildStep.writeAsString(outputId, result);
    }
  }

  String? _genContent(
    String content, {
    required String fileName,
    required String className,
    bool nullable = true,
    String? header,
  }) {
    final astResult = parseString(content: content);
    final targetClass = astResult.unit.declarations
        .whereType<ClassDeclaration>()
        .firstWhereOrNull((e) => e.namePart.typeName.lexeme == className);
    if (targetClass == null) {
      return null;
    }

    final methods = targetClass.body.members
        .whereType<MethodDeclaration>()
        .where((m) => m.isGetter || (!m.isGetter && !m.isSetter && !m.isStatic))
        .toList();
    if (methods.isEmpty) {
      return null;
    }

    final buffer = StringBuffer();
    buffer.writeAll([
      ?header,
      "import 'dart:ui';",
      "import '$fileName';",
      'extension ${className}Helper on $className{',
      'String${nullable ? "?" : ""} getTranslation(String key,{List<Object> args=const []}){',
      'switch(key){',
    ]);
    for (final method in methods) {
      final name = method.name.lexeme;
      buffer.write("case '$name':");
      if (method.isGetter) {
        buffer.write('return $name;');
      } else {
        final params =
            method.parameters?.parameters.toList(growable: false) ??
            const <FormalParameter>[];
        final argsList = <String>[];
        if (params.length > 1) {
          buffer.write(
            "assert(args.length>=${params.length},'Not enough parameters.');",
          );
        } else {
          buffer.write("assert(args.isNotEmpty,'Not enough parameters.');");
        }
        for (int i = 0; i < params.length; i++) {
          final p = params[i];
          final typeName = _getParamType(p);
          final isNamed = p.isNamed;
          final castExpr = 'args[$i] as $typeName';

          if (isNamed) {
            final paramName = _getParamName(p);
            argsList.add('$paramName: $castExpr');
          } else {
            argsList.add(castExpr);
          }
          buffer.write(
            "assert(args[$i] is $typeName,'The parameter type is incorrect.');",
          );
        }
        final callArgs = argsList.join(', ');
        buffer.write('return $name($callArgs);');
      }
    }
    buffer.write('default:return ${nullable ? "null" : "key"};}}');

    buffer.write('''static Locale? getLocaleFromLanguageTag(String code) {
        final tags = code.replaceAll('_', '-').split('-');
        final parseLanguageCode = tags.elementAtOrNull(0);
        final parseScriptCode = tags.length > 1 && tags[1].length == 4
            ? tags[1]
            : null;
        final parseCountryCode = tags.length > 1 && tags[1].length != 4
            ? tags[1]
            : tags.elementAtOrNull(2);
        for (final supported in $className.supportedLocales) {
          if (supported.languageCode != parseLanguageCode) {
            continue;
          }
          final scriptCode = supported.scriptCode;
          final countryCode = supported.countryCode;
          if (scriptCode == null && countryCode == null) {
            return supported;
          }
          if (scriptCode != null && scriptCode != parseScriptCode) {
            continue;
          }
          if (countryCode != null && countryCode != parseCountryCode) {
            continue;
          }
          return supported;
        }
        return null;
    }''');

    buffer.write('}');

    final formatter = DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
    );

    return formatter.format(buffer.toString());
  }

  String _getParamName(FormalParameter p) {
    final actualParam = p is DefaultFormalParameter ? p.parameter : p;
    if (actualParam is NormalFormalParameter) {
      return actualParam.name?.lexeme ?? '';
    }
    return '';
  }

  String _getParamType(FormalParameter p) {
    final actualParam = p is DefaultFormalParameter ? p.parameter : p;
    if (actualParam is SimpleFormalParameter) {
      return actualParam.type?.toSource() ?? 'dynamic';
    }
    if (actualParam is FunctionTypedFormalParameter) {
      return actualParam.toSource();
    }
    if (actualParam is FieldFormalParameter) {
      return actualParam.type?.toSource() ?? 'dynamic';
    }

    return 'dynamic';
  }
}
