import { stringToBoolean } from "./mappers";

/**
 * determines if a string[] contains exlusively booleans
 * @param strArr string[] to check
 * @returns true if strArr only contains booleans, false otherwise
 */
export const isBooleanArr = (strArr: string[]): boolean => {
  return strArr.every((element) => {
    try {
      stringToBoolean(element);
      return true;
    } catch {
      return false;
    }
  });
};
