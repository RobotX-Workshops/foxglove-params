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
