import { PanelExtensionContext } from "@foxglove/extension";
import { ReactElement, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

import { DefaultNumberParams } from "./constants/defaultValues";
import { buildSettingsTree, settingsActionReducer } from "./panelSettings";
import {
  NumericSettings,
  PanelSettings,
  PanelState,
  ParameterDetails,
  ParamsByNode,
  SelectSettings,
} from "./types";
import { parseParameters } from "./utils/mappers";

function loadInitialSettings(initial: unknown): PanelSettings {
  const state = initial as Partial<PanelState> | undefined;
  const partial = state?.settings as Partial<PanelSettings> | undefined;
  if (!partial) {
    return {
      selectedNode: "",
      selectedParameterName: "",
      inputType: "number",
    };
  }
  const numericPartial = partial as Partial<NumericSettings>;
  const selectPartial = partial as Partial<SelectSettings>;
  return {
    selectedNode: partial.selectedNode ?? "",
    selectedParameterName: partial.selectedParameterName ?? "",
    inputType: partial.inputType ?? "number",
    ...(numericPartial.min != undefined ? { min: numericPartial.min } : {}),
    ...(numericPartial.max != undefined ? { max: numericPartial.max } : {}),
    ...(numericPartial.step != undefined ? { step: numericPartial.step } : {}),
    ...(Array.isArray(selectPartial.selectOptions)
      ? { selectOptions: selectPartial.selectOptions }
      : {}),
    ...(selectPartial.selectOptionsAmount != undefined
      ? { selectOptionsAmount: selectPartial.selectOptionsAmount }
      : {}),
  } as PanelSettings;
}

function NumberInput({
  value,
  fullParamName,
  settings,
  setParameter,
}: {
  value: number;
  fullParamName: string;
  settings: PanelSettings;
  setParameter: (name: string, v: number) => void;
}): ReactElement {
  const [draft, setDraft] = useState<string | undefined>(undefined);
  const numberSettings = {
    ...DefaultNumberParams,
    ...settings,
  } as NumericSettings;
  const display = draft ?? String(value);

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <input
        type="number"
        min={numberSettings.min}
        max={numberSettings.max}
        step={numberSettings.step}
        value={display}
        onChange={(e) => {
          setDraft(e.target.value);
        }}
        onBlur={() => {
          if (draft != undefined) {
            const v = parseFloat(draft);
            if (Number.isFinite(v)) {
              setParameter(fullParamName, v);
            }
            setDraft(undefined);
          }
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.currentTarget.blur();
          }
        }}
        style={{
          padding: "0.3rem",
          margin: "0.3rem",
          width: "80%",
          minWidth: "60px",
        }}
      />
    </div>
  );
}

function SliderInput({
  value,
  fullParamName,
  settings,
  setParameter,
}: {
  value: number;
  fullParamName: string;
  settings: PanelSettings;
  setParameter: (name: string, v: number) => void;
}): ReactElement {
  const [localValue, setLocalValue] = useState<number>(value);
  const draggingRef = useRef(false);

  // Mirror incoming value when the user isn't actively dragging.
  useEffect(() => {
    if (!draggingRef.current) {
      setLocalValue(value);
    }
  }, [value]);

  const sliderSettings = {
    ...DefaultNumberParams,
    ...settings,
  } as NumericSettings;

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        justifyContent: "center",
        padding: "1rem",
      }}
    >
      <input
        type="range"
        min={sliderSettings.min}
        max={sliderSettings.max}
        step={sliderSettings.step}
        value={localValue}
        onPointerDown={() => {
          draggingRef.current = true;
        }}
        onPointerUp={() => {
          draggingRef.current = false;
        }}
        onPointerCancel={() => {
          draggingRef.current = false;
        }}
        onLostPointerCapture={() => {
          draggingRef.current = false;
        }}
        onChange={(e) => {
          const v = parseFloat(e.target.value);
          setLocalValue(v);
          setParameter(fullParamName, v);
        }}
        style={{ padding: "1rem", width: "calc(80% - 40px)" }}
      />
      <div>{localValue.toFixed(2)}</div>
    </div>
  );
}

function TextInput({
  value,
  fullParamName,
  setParameter,
}: {
  value: string;
  fullParamName: string;
  setParameter: (name: string, v: string) => void;
}): ReactElement {
  const [draft, setDraft] = useState<string | undefined>(undefined);
  const display = draft ?? value;
  return (
    <input
      type="text"
      value={display}
      onChange={(e) => {
        setDraft(e.target.value);
      }}
      onBlur={() => {
        if (draft != undefined) {
          setParameter(fullParamName, draft);
          setDraft(undefined);
        }
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.currentTarget.blur();
        }
      }}
      style={{ padding: "1rem" }}
    />
  );
}

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  const [settings, setSettings] = useState<PanelSettings>(() =>
    loadInitialSettings(context.initialState),
  );
  const [params, setParams] = useState<ParamsByNode>(() => new Map());

  useEffect(() => {
    context.watch("parameters");

    context.onRender = (renderState, done) => {
      if (renderState.parameters) {
        setParams(parseParameters(renderState.parameters));
      } else {
        setParams(new Map());
      }
      done();
    };

    // Empty subscription is enough to activate the render loop for "watched" fields.
    context.subscribe([]);

    return () => {
      context.unsubscribeAll();
    };
  }, [context]);

  useEffect(() => {
    context.saveState({ settings });
  }, [settings, context]);

  useEffect(() => {
    context.updatePanelSettingsEditor({
      actionHandler: (action) => {
        setSettings((prev) => settingsActionReducer(prev, action));
      },
      nodes: buildSettingsTree(settings, params),
    });
  }, [settings, params, context]);

  if (!settings.selectedNode) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Please select a node in the settings panel to view and edit its
          parameters. The available nodes will be populated once the WebSocket
          connection is established.
        </p>
      </div>
    );
  }

  if (!settings.selectedParameterName) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Please select a parameter from the settings panel to edit its value.
        </p>
      </div>
    );
  }

  if (params.size === 0) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>No parameters available for the selected node.</p>
      </div>
    );
  }

  const nodeParams: Array<ParameterDetails> =
    params.get(settings.selectedNode) ?? [];

  if (nodeParams.length === 0) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          No parameters found for the selected node: {settings.selectedNode}
        </p>
      </div>
    );
  }

  const fullParamName = `${settings.selectedNode}.${settings.selectedParameterName}`;

  const selectedParam = nodeParams.find(
    (param) => param.name === settings.selectedParameterName,
  );

  if (selectedParam == undefined) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Parameter &quot;{settings.selectedParameterName}&quot; not found for
          {settings.selectedNode}.
        </p>
      </div>
    );
  }

  const setNumberParameter = (name: string, v: number) => {
    context.setParameter(name, v);
  };
  const setStringParameter = (name: string, v: string) => {
    context.setParameter(name, v);
  };

  if (settings.inputType === "number") {
    const numVal = Number(selectedParam.value);
    if (isNaN(numVal)) {
      console.warn(
        `Expected number value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid number value</div>;
    }
    return (
      <NumberInput
        key={fullParamName}
        value={numVal}
        fullParamName={fullParamName}
        settings={settings}
        setParameter={setNumberParameter}
      />
    );
  }
  if (settings.inputType === "slider") {
    const numVal = Number(selectedParam.value);
    if (isNaN(numVal)) {
      console.warn(
        `Expected number value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid number value</div>;
    }
    return (
      <SliderInput
        key={fullParamName}
        value={numVal}
        fullParamName={fullParamName}
        settings={settings}
        setParameter={setNumberParameter}
      />
    );
  }
  if (settings.inputType === "boolean") {
    if (typeof selectedParam.value !== "boolean") {
      console.warn(
        `Expected boolean value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid boolean value</div>;
    }
    return (
      <div
        style={{
          display: "flex",
          flexDirection: "row",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <input
          type="checkbox"
          checked={selectedParam.value}
          onChange={(e) => {
            context.setParameter(fullParamName, e.target.checked);
          }}
          style={{
            padding: "1rem",
          }}
        />
      </div>
    );
  }
  if (settings.inputType === "text") {
    if (typeof selectedParam.value !== "string") {
      console.warn(
        `Expected string value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid text value</div>;
    }
    return (
      <TextInput
        key={fullParamName}
        value={selectedParam.value}
        fullParamName={fullParamName}
        setParameter={setStringParameter}
      />
    );
  }
  // Defensive runtime gate: legacy panel state persisted before the dropdown was tightened
  // could still carry an inputType outside the current PanelSettings union.
  // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
  if (settings.inputType === "select") {
    if (typeof selectedParam.value !== "string") {
      console.warn(
        `Expected string value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid string value</div>;
    }
    const selectSettings = settings as SelectSettings;
    const options = selectSettings.selectOptions ?? [];
    return (
      <div
        style={{
          display: "flex",
          flexDirection: "row",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <select
          value={selectedParam.value}
          onChange={(e) => {
            context.setParameter(fullParamName, e.target.value);
          }}
          style={{
            padding: "0.3rem",
            margin: "0.3rem",
            width: "80%",
          }}
        >
          {options.map((option, i) => (
            <option key={i} value={option}>
              {option}
            </option>
          ))}
        </select>
      </div>
    );
  }
  return <div>Unknown input type</div>;
}

export function initEditParamPanel(context: PanelExtensionContext): () => void {
  const root = createRoot(context.panelElement);
  root.render(<EditParamPanel context={context} />);
  return () => {
    root.unmount();
  };
}
