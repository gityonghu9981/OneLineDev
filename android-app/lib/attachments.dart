// attachments.dart —— 图片 / 文件 附件选择模块
// 职责（单一解耦，聊天页只调用）：
//   选手机图片 → base64 + mime；选手机文本文件 → 读内容。
//   返回统一附件结构，供发送给中转（中转 multimodal 模块转成模型输入）。
// 后续加新附件类型（音频、PDF）只改本文件，不动聊天逻辑。
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

class AttachmentPicker {
  /// 从手机相册/图库选一张图，压缩后转 base64。
  /// 返回 [{type:'image', name, mime, data_b64}] 或 null（取消）。
  static Future<Map<String, dynamic>?> pickImage() async {
    final picker = ImagePicker();
    final XFile? x = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 82,
    );
    if (x == null) return null;
    final bytes = await x.readAsBytes();
    final ext = x.path.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/png',
    };
    return {
      'type': 'image',
      'name': x.name,
      'mime': mime,
      'data_b64': base64Encode(bytes),
    };
  }

  /// 从手机选一个文件，按文本读取内容。
  /// 返回 [{type:'file', name, text}] 或 null（取消/非文本）。
  static Future<Map<String, dynamic>?> pickTextFile() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return null;
    final f = files.single;
    final bytes = await f.readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.trim().isEmpty) return null;
    return {'type': 'file', 'name': f.name, 'text': text};
  }

  /// 附件文件大小的友好显示（给聊天输入区/列表用）。
  static String bytesLabel(int len) {
    if (len >= 1024 * 1024) return '${(len / (1024 * 1024)).toStringAsFixed(1)}MB';
    if (len >= 1024) return '${(len / 1024).toStringAsFixed(0)}KB';
    return '$len B';
  }
}
