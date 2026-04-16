import { useEffect, useRef, useState } from "react";

const GOOGLE_MAPS_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY || "";

let scriptLoading = false;
let scriptLoaded = false;
const loadCallbacks: (() => void)[] = [];

function loadGoogleMaps(): Promise<void> {
  if (scriptLoaded) return Promise.resolve();
  if (!GOOGLE_MAPS_KEY) return Promise.reject(new Error("No Google Maps API key"));
  return new Promise((resolve, reject) => {
    loadCallbacks.push(resolve);
    if (scriptLoading) return;
    scriptLoading = true;
    const script = document.createElement("script");
    script.src = `https://maps.googleapis.com/maps/api/js?key=${GOOGLE_MAPS_KEY}&libraries=places`;
    script.async = true;
    script.onload = () => {
      scriptLoaded = true;
      loadCallbacks.forEach((cb) => cb());
      loadCallbacks.length = 0;
    };
    script.onerror = () => reject(new Error("Failed to load Google Maps"));
    document.head.appendChild(script);
  });
}

interface AddressAutocompleteProps {
  value: string;
  onChange: (value: string) => void;
  onSelect?: (place: { address: string; lat?: number; lng?: number }) => void;
  placeholder?: string;
  className?: string;
  style?: React.CSSProperties;
  types?: string[];
}

export default function AddressAutocomplete({
  value,
  onChange,
  onSelect,
  placeholder = "Enter address",
  className = "form-input",
  style,
  types,
}: AddressAutocompleteProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const autocompleteRef = useRef<google.maps.places.Autocomplete | null>(null);
  const onChangeRef = useRef(onChange);
  const onSelectRef = useRef(onSelect);
  const [ready, setReady] = useState(scriptLoaded);

  // Keep refs current without triggering re-init
  onChangeRef.current = onChange;
  onSelectRef.current = onSelect;

  useEffect(() => {
    if (!GOOGLE_MAPS_KEY) return;
    loadGoogleMaps().then(() => setReady(true)).catch(() => {});
  }, []);

  useEffect(() => {
    if (!inputRef.current || !ready || autocompleteRef.current) return;
    const ac = new google.maps.places.Autocomplete(inputRef.current, {
      types: types || ["geocode"],
      componentRestrictions: { country: "us" },
      fields: ["formatted_address", "geometry"],
    });
    ac.addListener("place_changed", () => {
      const place = ac.getPlace();
      const addr = place.formatted_address || "";
      onChangeRef.current(addr);
      onSelectRef.current?.({
        address: addr,
        lat: place.geometry?.location?.lat(),
        lng: place.geometry?.location?.lng(),
      });
    });
    autocompleteRef.current = ac;
  }, [ready, types]);

  return (
    <input
      ref={inputRef}
      type="text"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      className={className}
      style={style}
      autoComplete="off"
    />
  );
}
