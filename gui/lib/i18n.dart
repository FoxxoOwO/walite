/// Lightweight Czech/English localization matching `src/i18n.rs`.
class Tr {
  Tr(this.lang);

  final String lang;

  bool get isEn => lang == 'en';

  String t(String cs, String en) => isEn ? en : cs;
}
