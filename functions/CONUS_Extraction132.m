
%% download_USCRN_soilmoisture.m
% NOAA USCRN hourly observations, CONUS
% Period: 1 June 2026 through the latest timestamp available.
% MATLAB R2021b
%
% Outputs:
%   USCRN_CONUS_SM_20260601_to_now.csv
%   USCRN_CONUS_station_inventory.csv
%
% BaseSM = SOIL_MOISTURE_5, volumetric soil moisture at 5 cm,
% in m^3/m^3.
%
% NOAA hourly02 documented columns:
%   2  = UTC_DATE
%   3  = UTC_TIME
%   7  = LONGITUDE
%   8  = LATITUDE
%   29 = SOIL_MOISTURE_5
%
% Official column definitions:
% https://www.ncei.noaa.gov/pub/data/uscrn/products/hourly02/headers.txt

clear; clc;

%% Configuration

startTime = datetime(2026,6,1,0,0,0,'TimeZone','UTC');
endTime   = datetime('now','TimeZone','UTC');

baseURL = ...
    'https://www.ncei.noaa.gov/pub/data/uscrn/products/hourly02/2026/';

outFile = 'USCRN_CONUS_SM_20260601_to_now.csv';
inventoryFile = 'USCRN_CONUS_station_inventory.csv';
cacheFolder = fullfile(pwd,'USCRN_cache');

if ~exist(cacheFolder,'dir')
    mkdir(cacheFolder);
end

% Contiguous United States, including DC.
conusStates = { ...
    'AL','AZ','AR','CA','CO','CT','DE','FL','GA','ID', ...
    'IL','IN','IA','KS','KY','LA','ME','MD','MA','MI', ...
    'MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY', ...
    'NC','ND','OH','OK','OR','PA','RI','SC','SD','TN', ...
    'TX','UT','VT','VA','WA','WV','WI','WY','DC'};

%% 1. Read the official NOAA archive listing

fprintf('Reading NOAA archive: %s\n',baseURL);

try
    html = webread(baseURL);
catch ME
    error('Cannot access NOAA archive: %s',ME.message);
end

% Extract official annual station-file names.
tokens = regexp(html, ...
    'CRNH0203-2026-[A-Z]{2}_[^"<>\s]+\.txt', ...
    'match');

fileNames = unique(tokens,'stable');

if isempty(fileNames)
    error(['No annual station files found. The archive may have ' ...
           'changed or may be temporarily unavailable.']);
end

% Restrict to CONUS states.
keep = false(size(fileNames));

for k = 1:numel(fileNames)
    tok = regexp(fileNames{k}, ...
        'CRNH0203-2026-([A-Z]{2})_', ...
        'tokens','once');

    if ~isempty(tok)
        keep(k) = ismember(tok{1},conusStates);
    end
end

fileNames = fileNames(keep);

fprintf('CONUS annual files found: %d\n',numel(fileNames));

%% 2. Download and process the station files

parts = cell(numel(fileNames),1);
nDownloaded = 0;
nFailed = 0;

for k = 1:numel(fileNames)

    fn = fileNames{k};
    localFile = fullfile(cacheFolder,fn);
    fileURL = [baseURL fn];

    try
        % Download if not already cached.
        if ~exist(localFile,'file')
            websave(localFile,fileURL);
        end

        % Read whitespace-separated NOAA data.
        % MultipleDelimsAsOne is important because the fields are
        % separated by variable numbers of spaces.
        A = readtable(localFile, ...
            'FileType','text', ...
            'Delimiter',' ', ...
            'MultipleDelimsAsOne',true, ...
            'ReadVariableNames',false, ...
            'TextType','string');

        if width(A) ~= 38
            warning('%s: expected 38 columns, found %d. Skipping.', ...
                fn,width(A));
            nFailed = nFailed + 1;
            continue
        end

        % Extract the documented NOAA fields.
        dateNum = str2double(string(A{:,2}));
        timeNum = str2double(string(A{:,3}));

        lon = str2double(string(A{:,7}));
        lat = str2double(string(A{:,8}));

        % CORRECTION: column 29 is SOIL_MOISTURE_5.
        % Column 28 is RH_HR_AVG_FLAG and must NOT be used.
        sm5 = str2double(string(A{:,29}));

        wban = string(A{:,1});

        % Build UTC timestamps.
        dateText = compose('%08.0f',dateNum);
        timeText = compose('%04.0f',timeNum);

        dt = NaT(height(A),1,'TimeZone','UTC');

        dateOK = isfinite(dateNum) & isfinite(timeNum);

        if any(dateOK)
            dt(dateOK) = datetime( ...
                dateText(dateOK) + " " + timeText(dateOK), ...
                'InputFormat','yyyyMMdd HHmm', ...
                'TimeZone','UTC');
        end

        % Basic geographic and physical checks.
        valid = ~isnat(dt) & ...
            dt >= startTime & dt <= endTime & ...
            isfinite(lat) & isfinite(lon) & ...
            lat >= 24 & lat <= 50 & ...
            lon >= -126 & lon <= -66 & ...
            isfinite(sm5) & sm5 >= 0 & sm5 <= 1;

        if ~any(valid)
            fprintf('No valid observations in %s\n',fn);
            continue
        end

        % Retain the original WBAN station identifier and filename.
        n = sum(valid);

        T = table( ...
            dt(valid), ...
            wban(valid), ...
            repmat(string(fn),n,1), ...
            lat(valid), ...
            lon(valid), ...
            sm5(valid), ...
            'VariableNames', ...
            {'DateTime','WBAN','StationFile','Lat','Lon','BaseSM'});

        parts{k} = T;
        nDownloaded = nDownloaded + 1;

        % Diagnostic: report the actual values read from column 29.
        fprintf(['%3d/%3d  %-45s  N=%6d  ' ...
                 'SM5 min=%6.3f max=%6.3f mean=%6.3f\n'], ...
            k,numel(fileNames),fn,n, ...
            min(sm5(valid)),max(sm5(valid)),mean(sm5(valid)));

    catch ME
        warning('Failed to process %s: %s',fn,ME.message);
        nFailed = nFailed + 1;
    end
end

%% 3. Combine all station observations

parts = parts(~cellfun(@isempty,parts));

if isempty(parts)
    error(['No valid observations were obtained. Check the archive, ' ...
           'column layout, dates and downloaded files.']);
end

SM = vertcat(parts{:});
SM = sortrows(SM,{'WBAN','DateTime'});

%% 4. Diagnostics to detect the previous all-zero problem

fprintf('\n===== FINAL DATASET CHECK =====\n');
fprintf('Time interval: %s to %s UTC\n', ...
    char(startTime),char(endTime));
fprintf('Files with observations: %d\n',nDownloaded);
fprintf('Files skipped or failed: %d\n',nFailed);
fprintf('Total observations: %d\n',height(SM));
fprintf('Unique WBAN stations: %d\n',numel(unique(SM.WBAN)));
fprintf('BaseSM minimum: %.5f m^3/m^3\n',min(SM.BaseSM));
fprintf('BaseSM maximum: %.5f m^3/m^3\n',max(SM.BaseSM));
fprintf('BaseSM mean:    %.5f m^3/m^3\n',mean(SM.BaseSM));
fprintf('Fraction exactly zero: %.2f %%\n', ...
    100*mean(SM.BaseSM == 0));

if all(SM.BaseSM == 0)
    warning(['All extracted soil-moisture values are zero. ' ...
        'Inspect a raw station file and verify column 29.']);
end

%% 5. Save the full time series

writetable(SM,outFile);

%% 6. Save the unique station inventory

% A station may have small coordinate variations between records.
% Use the first observation per WBAN for its inventory coordinates.
[~,firstIdx] = unique(SM.WBAN,'stable');

Stations = SM(firstIdx,{'WBAN','StationFile','Lat','Lon'});
Stations = sortrows(Stations,'WBAN');

writetable(Stations,inventoryFile);

fprintf('\nSaved time series: %s\n',outFile);
fprintf('Saved inventory:   %s\n',inventoryFile);
fprintf('===============================\n');
