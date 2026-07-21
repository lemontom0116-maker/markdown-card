const compositionStates = new WeakMap();

function stateFor(document) {
  let state = compositionStates.get(document);
  if (state) return state;
  state = {
    depth: 0,
    installed: false,
    cleanup: null,
    onChange: null,
    lastReportedValue: null
  };
  compositionStates.set(document, state);
  return state;
}

export function installCompositionGuard(document, onChange = null) {
  const state = stateFor(document);
  if (state.installed) {
    onChange?.(state.depth > 0);
    return state.cleanup;
  }

  state.onChange = typeof onChange === "function" ? onChange : null;
  const report = (value) => {
    if (state.lastReportedValue === value) return;
    state.lastReportedValue = value;
    state.onChange?.(value);
  };

  const begin = () => {
    state.depth += 1;
    report(true);
  };
  const end = () => {
    state.depth = Math.max(0, state.depth - 1);
    report(state.depth > 0);
  };
  const reset = () => {
    state.depth = 0;
    report(false);
  };

  document.addEventListener("compositionstart", begin, true);
  document.addEventListener("compositionend", end, true);
  document.defaultView?.addEventListener?.("blur", reset);
  document.defaultView?.addEventListener?.("pagehide", reset);
  state.installed = true;
  report(false);
  state.cleanup = () => {
    if (!state.installed) return;
    reset();
    document.removeEventListener("compositionstart", begin, true);
    document.removeEventListener("compositionend", end, true);
    document.defaultView?.removeEventListener?.("blur", reset);
    document.defaultView?.removeEventListener?.("pagehide", reset);
    state.depth = 0;
    state.installed = false;
    state.cleanup = null;
    state.onChange = null;
    state.lastReportedValue = null;
  };
  return state.cleanup;
}

export function documentIsComposing(document) {
  return Boolean(document && stateFor(document).depth > 0);
}

export function isIMECompositionEvent(event, view = null) {
  const document = event?.target?.ownerDocument
    ?? view?.dom?.ownerDocument
    ?? null;
  return Boolean(
    event?.isComposing
    || event?.keyCode === 229
    || view?.composing
    || documentIsComposing(document)
  );
}

export function editorIsComposing(editor) {
  return Boolean(
    editor?.view?.composing
    || documentIsComposing(editor?.view?.dom?.ownerDocument)
  );
}
