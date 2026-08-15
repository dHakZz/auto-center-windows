ObjC.import('Cocoa');

function run(argv) {
  const mode = String(argv[0] || '');
  if (mode === 'validate') return 'ok';
  if (mode === 'notify-settings') {
    $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObject(
      'com.justin.auto-center-windows.show-settings',
      undefined
    );
    return '';
  }
  if (mode === 'prompt') {
    return promptForApps(
      String(argv[1] || 'Auto Center Windows'),
      String(argv[2] || ''),
      String(argv[3] || ''),
      String(argv[4] || 'Save')
    );
  }
  if (mode === 'confirm') {
    return confirmAction(
      String(argv[1] || 'Auto Center Windows'),
      String(argv[2] || ''),
      String(argv[3] || 'Continue')
    );
  }
  showAlert(
    String(argv[1] || 'Auto Center Windows'),
    String(argv[2] || ''),
    mode === 'error'
  );
  return '';
}

function activateAlert(alert) {
  const app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
  app.activateIgnoringOtherApps(true);
  alert.window.level = $.NSFloatingWindowLevel;
  alert.window.center;
  alert.window.makeKeyAndOrderFront(undefined);
  alert.window.orderFrontRegardless;
}

function promptForApps(title, message, currentValue, actionTitle) {
  const alert = $.NSAlert.alloc.init;
  alert.messageText = title;
  alert.informativeText = message;
  alert.addButtonWithTitle(actionTitle);
  alert.addButtonWithTitle('Cancel');

  const field = $.NSTextField.alloc.initWithFrame($.NSMakeRect(0, 0, 420, 24));
  field.stringValue = currentValue;
  field.placeholderString = 'Safari, Messages, Notes';
  alert.accessoryView = field;

  activateAlert(alert);
  const response = Number(alert.runModal);
  if (response !== Number($.NSAlertFirstButtonReturn)) return '__AUTO_CENTER_CANCELLED__';
  return ObjC.unwrap(field.stringValue);
}

function confirmAction(title, message, actionTitle) {
  const alert = $.NSAlert.alloc.init;
  alert.alertStyle = $.NSAlertStyleWarning;
  alert.messageText = title;
  alert.informativeText = message;
  alert.addButtonWithTitle(actionTitle);
  alert.addButtonWithTitle('Cancel');
  activateAlert(alert);
  const response = Number(alert.runModal);
  return response === Number($.NSAlertFirstButtonReturn) ? 'confirmed' : '__AUTO_CENTER_CANCELLED__';
}

function showAlert(title, message, isError) {
  const alert = $.NSAlert.alloc.init;
  alert.alertStyle = isError ? $.NSAlertStyleCritical : $.NSAlertStyleInformational;
  alert.messageText = title;
  alert.informativeText = message;
  alert.addButtonWithTitle('Done');
  activateAlert(alert);
  alert.runModal;
}
