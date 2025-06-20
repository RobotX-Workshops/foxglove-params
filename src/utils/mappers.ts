import { ParameterDetails, ParameterValueDetails } from "parameter_types";

/**
 * converts string representation of a boolean to a boolean
 * @param stringValue "true" or "false"
 * @returns true or false
 */
export const stringToBoolean = (stringValue: string): boolean => {
  switch (stringValue.toLowerCase().trim()) {
    case "true":
      return true;
    case "on":
      return true;
    case "false":
      return false;
    case "off":
      return false;
    default:
      throw new Error(`Invalid boolean string: ${stringValue}`);
  }
};

// Helper to parse the raw parameter data string (replaces extractNodeNames from example)
export function extractNodeNames(data: string): string[] {
  if (!data) {
    return [];
  }
  try {
    // Explicitly type the expected structure from JSON.parse
    // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
    const parsed: { parameters?: { name: string }[] } = JSON.parse(data);

    if (!parsed.parameters || !Array.isArray(parsed.parameters)) {
      return [];
    }

    // Safely extract node names
    const nodeNames = new Set(
      parsed.parameters
        .map((p) => p.name.split(".")[0])
        .filter((namePart): namePart is string => !!namePart),
    );
    return Array.from(nodeNames);
  } catch (e) {
    console.error("Failed to parse parameter data:", e);
    return [];
  }
}

// Helper to parse parameters for a specific node (replaces extractParametersByNode)
export function extractParametersForNode(
  data: string,
  nodeName: string,
): ParameterDetails[] {
  if (!data || !nodeName) {
    return [];
  }
  try {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
    const parsed = JSON.parse(data);
    // eslint-disable-next-line @typescript-eslint/strict-boolean-expressions, @typescript-eslint/no-unsafe-member-access
    if (!parsed.parameters || !Array.isArray(parsed.parameters)) {
      return [];
    }

    const nodeParams: ParameterDetails[] = [];
    // eslint-disable-next-line @typescript-eslint/no-unsafe-call, @typescript-eslint/no-unsafe-member-access
    parsed.parameters.forEach(
      (param: { name: string; value: ParameterValueDetails }) => {
        const paramName = param.name;
        const nodePrefix = `${nodeName}.`;
        const paramNameWithoutNode = param.name.replace(nodePrefix, "");
        const value = param.value;
        if (paramName.startsWith(nodePrefix)) {
          nodeParams.push({
            name: paramNameWithoutNode,
            value,
          });
        }
      },
    );
    return nodeParams;
  } catch (e) {
    console.error("Failed to extract parameters for node:", e);
    return [];
  }
}
