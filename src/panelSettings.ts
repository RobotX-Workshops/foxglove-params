import {
  SettingsTreeNodes,
  SettingsTreeFields,
  SettingsTreeAction,
} from "@foxglove/extension";
import { produce } from "immer";
import * as _ from "lodash-es";

import { DefaultNumberParams } from "./constants/defaultValues";
import {
  PanelSettings,
  Settings,
  NumericSettings,
  SelectSettings,
  ParameterDetails,
  ParamsByNode,
} from "./types";

export function settingsActionReducer(
  prevConfig: Settings,
  action: SettingsTreeAction,
): Settings {
  return produce(prevConfig, (draft) => {
    if (action.action === "update") {
      const { path, value } = action.payload;
      const field = path[path.length - 1];

      // Initialize selectOptions when switching to "select" input type
      if (field === "inputType" && value === "select") {
        const selectDraft = draft as SelectSettings;
        if (!Array.isArray(selectDraft.selectOptions)) {
          selectDraft.selectOptions = [];
          selectDraft.selectOptionsAmount = 0;
        }
        selectDraft.inputType = "select";
        return;
      }

      // Resize selectOptions array when selectOptionsAmount changes
      if (field === "selectOptionsAmount") {
        const selectDraft = draft as SelectSettings;
        if (!Array.isArray(selectDraft.selectOptions)) {
          selectDraft.selectOptions = [];
        }
        const parsed = Math.floor(Number(value));
        const newAmount = Number.isFinite(parsed) ? Math.max(0, parsed) : 0;
        if (newAmount > selectDraft.selectOptions.length) {
          for (let i = selectDraft.selectOptions.length; i < newAmount; i++) {
            selectDraft.selectOptions.push("");
          }
        } else {
          selectDraft.selectOptions.splice(newAmount);
        }
        selectDraft.selectOptionsAmount = newAmount;
        return;
      }

      // Map selectOption{i} field updates into the selectOptions array
      const selectOptionMatch =
        typeof field === "string" ? /^selectOption(\d+)$/.exec(field) : null;
      if (selectOptionMatch) {
        const index = parseInt(selectOptionMatch[1]!, 10);
        const selectDraft = draft as SelectSettings;
        if (!Array.isArray(selectDraft.selectOptions)) {
          selectDraft.selectOptions = [];
        }
        selectDraft.selectOptions[index] = String(value);
        return;
      }

      _.set(draft, path.slice(1), value);
    }
  });
}

export function buildSettingsTree(
  config: PanelSettings,
  params: ParamsByNode,
): SettingsTreeNodes {
  const selectedNodeParams: Array<ParameterDetails> =
    params.get(config.selectedNode) ?? [];
  const inputOptions = [];

  if (
    selectedNodeParams.find((param) => typeof param.value === "boolean") !=
    undefined
  ) {
    inputOptions.push({
      label: "Boolean",
      value: "boolean",
    });
  }
  if (selectedNodeParams.find((param) => typeof param.value === "string")) {
    inputOptions.push({
      label: "Text",
      value: "text",
    });
    inputOptions.push({
      label: "Select",
      value: "select",
    });
  }
  if (selectedNodeParams.find((param) => typeof param.value === "number")) {
    inputOptions.push({
      label: "Number",
      value: "number",
    });
    inputOptions.push({
      label: "Slider",
      value: "slider",
    });
  }
  const dataSourceFields: SettingsTreeFields = {
    selectedNode: {
      label: "Node",
      input: "select",
      value: config.selectedNode,
      options: Array.from(params.keys()).map((nodeName) => ({
        label: nodeName,
        value: nodeName,
      })),
    },
    selectedParameterName: {
      label: "Parameter",
      input: "select",
      disabled: selectedNodeParams.length === 0,
      value: config.selectedParameterName,
      options: selectedNodeParams.map((param: ParameterDetails) => ({
        label: param.name,
        value: param.name,
      })),
    },
    inputType: {
      label: "Input Type",
      input: "select",
      value: config.inputType,
      options: inputOptions,
    },
  };

  if (config.inputType === "slider") {
    const tempSettings = { ...DefaultNumberParams, ...config };
    const numSettings = tempSettings as NumericSettings;
    dataSourceFields["min"] = {
      label: "Min",
      input: "number",
      value: numSettings.min,
    };
    dataSourceFields["max"] = {
      label: "Max",
      input: "number",
      value: numSettings.max,
    };
    dataSourceFields["step"] = {
      label: "Step",
      input: "number",
      value: numSettings.step,
    };
  }

  if (config.inputType === "number") {
    const tempSettings = { ...DefaultNumberParams, ...config };
    const numSettings = tempSettings as NumericSettings;
    dataSourceFields["min"] = {
      label: "Min",
      input: "number",
      value: numSettings.min,
    };
    dataSourceFields["max"] = {
      label: "Max",
      input: "number",
      value: numSettings.max,
    };
    dataSourceFields["step"] = {
      label: "Step",
      input: "number",
      value: numSettings.step,
    };
  }
  const settings: SettingsTreeNodes = {
    dataSource: {
      label: "Parameter",
      icon: "Settings",
      fields: dataSourceFields,
    },
  };

  if (config.inputType === "select") {
    // eslint-disable-next-line no-var
    var selectSettings = config as SelectSettings;
    const selectOptions = selectSettings.selectOptions ?? [];
    dataSourceFields["selectOptionsAmount"] = {
      label: "Select Options Amount",
      input: "number",
      value: selectOptions.length,
    };

    for (let i = 0; i < selectOptions.length; i++) {
      dataSourceFields[`selectOption${i}`] = {
        label: `Select Option ${i + 1}`,
        input: "string",
        value: selectOptions[i],
        placeholder: `Option ${i + 1}`,
      };
    }
  }
  return settings;
}
