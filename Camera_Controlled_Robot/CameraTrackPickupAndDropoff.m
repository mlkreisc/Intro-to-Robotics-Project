% CameraTrackAndPickup.m
% Horizontal base-only tracking + pick-and-place.
% Sequence:
%   1) Select a block color (not Blue) -> align -> pickup
%   2) Search for Blue dot -> align -> dropoff
%   3) Wait for next block color selection -> repeat with shorter initial sweep
%
% Arduino commands (ManualPulseControl_dbg.ino):
%   q/a : base
%   r/f : shoulder
%   e/d : gripper close/open
%   x   : stop

clearvars
close all
clear('cam');

%% Settings
serialPort = "COM4";
baudRate   = 115200;

baseAngle0 = 0.0;
baseLimits = [-135, 135];

pixelsPerDegBase = 6.0;
degPerPulseBase  = 0.5;

maxPulsesPerLoop  = 1;
interPulsePause   = 0.06;
loopDelay         = 0.08;

lockFrames         = 5;
lockTolerancePx    = 15;
deadzonePx         = lockTolerancePx;
unlockTolerancePx  = 16;

sweepPulsesPerIter = 1;

sweepQCount_1 = 56;
sweepACount_1 = 56;

sweepQCount_2 = 25;
sweepACount_2 = 55;

colorOptions = [{'Select color'}, {'Green','Red','Blue','Yellow','Purple'}];

%% Camera
if any(strcmpi(webcamlist,"Logi C270 HD Webcam"))
    cam = webcam("Logi C270 HD Webcam");
else
    cam = webcam;
end

% Adjustment (3): force a smaller resolution for faster snapshot + processing
try
    cam.Resolution = "640x480";
catch
end

RGB = snapshot(cam);
[H, W, ~] = size(RGB);

%% UI
fMain = figure(1); clf(fMain);
t = tiledlayout(fMain, 2, 2, 'TileSpacing','compact', 'Padding','compact');

ax1 = nexttile(t,1);
h1 = imshow(zeros(H,W,3,'uint8'),'Parent',ax1); title(ax1,'Original');

ax2 = nexttile(t,2);
h2 = imshow(zeros(H,W,3,'uint8'),'Parent',ax2); title(ax2,'Masked');

ax3 = nexttile(t,3);
h3 = imshow(false(H,W),'Parent',ax3); title(ax3,'Mask'); hold(ax3,'on');
hStar = plot(ax3, NaN, NaN, 'm*', 'MarkerSize', 12, 'LineWidth', 1.5);
hLock = plot(ax3, NaN, NaN, 'og', 'MarkerSize', 28, 'LineWidth', 1);
set(hLock,'Visible','off');

ax4 = nexttile(t,4);
axis(ax4,'off');
statusTxt = text(ax4, 0.5, 0.72, 'Status: select a color', ...
    'HorizontalAlignment','center', 'FontWeight','bold', 'FontSize', 12);
angleTxt  = text(ax4, 0.5, 0.45, sprintf('Base=%.1f°', baseAngle0), ...
    'HorizontalAlignment','center', 'FontSize', 11);

uicontrol('Parent', fMain, 'Style', 'text', 'Units','normalized', ...
    'Position',[0.77 0.45 0.12 0.04], 'String','Color:', 'HorizontalAlignment','left');
popupColor = uicontrol('Parent', fMain, 'Style', 'popupmenu', 'Units','normalized', ...
    'Position',[0.77 0.40 0.18 0.05], 'String', colorOptions, 'Value', 1);

se = strel('disk',5);

%% Serial
s = serialport(serialPort, baudRate, "Timeout", 2);
configureTerminator(s,"LF");
flush(s);

setappdata(fMain, 'serial', s);
setappdata(fMain, 'stopRequested', false);

uicontrol('Parent',fMain, 'Style','pushbutton', 'String','EMERGENCY STOP', ...
    'FontWeight','bold', 'BackgroundColor',[1 0.2 0.2], 'ForegroundColor','w', ...
    'Units','normalized', 'Position',[0.01 0.02 0.16 0.06], ...
    'Callback', @(~,~) emergencyStop(fMain));

set(fMain, 'KeyPressFcn', @keyPressCB);

%% State
baseAngle = baseAngle0;

isLocked         = false;
horizLockCounter = 0;
lockedMean       = [NaN NaN];

mode = 'pickup';          % 'pickup' | 'dropoff' | 'wait_newcolor'
pickupDone  = false;
dropoffDone = false;
secondCycle = false;

sweepActive          = false;
sweepPhase           = 'idle'; % 'idle' -> 'q' -> 'a' -> 'done'
sweepRemainingPulses = 0;
sweepCmd             = '';
sweepSign            = 0;
sweepQCount          = sweepQCount_1;
sweepACount          = sweepACount_1;

fprintf("Ready (%s @ %d)\n", serialPort, baudRate);

%% Loop
try
    while ~getappdata(fMain,'stopRequested') && ishghandle(fMain)

        RGB = snapshot(cam);
        set(h1,'CData',RGB);

        selIdx    = popupColor.Value;
        selString = popupColor.String{selIdx};

        % Adjustment (2): hard idle in wait_newcolor (no search, no detection)
        if strcmp(mode,'wait_newcolor')
            set(statusTxt,'String','Status: waiting for new color (not Blue)');
            BW = false(H,W);
            set(h3,'CData',BW);
            set(h2,'CData',RGB.*uint8(repmat(BW,[1 1 3])));
            set(hStar,'XData',NaN,'YData',NaN);
            set(hLock,'Visible','off');
            drawnow limitrate;
            pause(loopDelay);

            if ~(strcmp(selString,'Select color') || strcmpi(selString,'Blue'))
                mode        = 'pickup';
                pickupDone  = false;
                dropoffDone = false;
                secondCycle = true;

                sweepQCount = sweepQCount_2;
                sweepACount = sweepACount_2;

                sweepActive = false;
                sweepPhase  = 'idle';
                sweepRemainingPulses = 0;
                sweepCmd  = '';
                sweepSign = 0;

                horizLockCounter = 0;
                isLocked = false;

                fprintf("New pickup color: %s\n", selString);
            end
            continue; % critical: prevents searching from resuming automatically
        end

        % Decide which color to detect
        if strcmp(mode,'pickup')
            if strcmp(selString,'Select color')
                BW = false(H,W);
                set(h3,'CData',BW);
                set(h2,'CData',RGB.*uint8(repmat(BW,[1 1 3])));
                if ~secondCycle
                    set(statusTxt,'String','Status: select a pickup color');
                else
                    set(statusTxt,'String','Status: select next pickup color');
                end
                drawnow limitrate;
                pause(loopDelay);
                continue;
            end
            colorVal = selString;
        else
            colorVal = 'Blue';
        end

        % Mask
        [Hmin,Hmax,Smin,Vmin] = getColorThresholds(colorVal);
        I  = rgb2hsv(RGB);
        Hh = I(:,:,1); Ss = I(:,:,2); Vv = I(:,:,3);
        BW = (Hh >= Hmin & Hh <= Hmax) & (Ss >= Smin) & (Vv >= Vmin);

        BW = imopen(BW,se);
        BW = imclose(BW,se);
        BW = bwareaopen(BW,200);

        set(h3,'CData',BW);
        masked = RGB; masked(repmat(~BW,[1 1 3])) = 0;
        set(h2,'CData',masked);

        CC = bwconncomp(BW);

        if CC.NumObjects > 0
            if sweepActive
                sweepActive = false;
                sweepPhase  = 'idle';
                sweepRemainingPulses = 0;
                sweepCmd  = '';
                sweepSign = 0;
                write(s, 'x', "char"); pause(0.02);
            end

            sStat = regionprops(CC,'Centroid','Area');
            [~,ind] = max([sStat.Area]);
            c = sStat(ind).Centroid;
            objX = c(1); objY = c(2);
            set(hStar,'XData',objX,'YData',objY);

            cx   = W/2;
            errX = cx - objX;

            if abs(errX) <= lockTolerancePx
                horizLockCounter = min(horizLockCounter + 1, lockFrames);
            else
                horizLockCounter = 0;
            end

            if ~isLocked
                if horizLockCounter >= lockFrames
                    isLocked   = true;
                    lockedMean = [objX, objY];
                    set(hLock,'XData',lockedMean(1),'YData',lockedMean(2),'Visible','on');
                    write(s, 'x', "char"); pause(0.02);

                    if strcmp(mode,'pickup') && ~pickupDone
                        set(statusTxt, 'String', sprintf('Locked: pickup (%s)', colorVal));
                        fprintf("Pickup: %s\n", colorVal);
                        pickup_block(s);
                        pickupDone = true;

                        mode = 'dropoff';
                        isLocked = false;
                        horizLockCounter = 0;
                        set(hLock,'Visible','off');
                        set(statusTxt,'String','Searching: dropoff (Blue)');
                        pause(0.1);

                    elseif strcmp(mode,'dropoff') && ~dropoffDone
                        set(statusTxt, 'String', 'Locked: dropoff (Blue)');
                        fprintf("Dropoff: Blue\n");
                        dropoff_block(s);
                        dropoffDone = true;

                        % Adjustment (2): force idle and clear sweep state
                        mode = 'wait_newcolor';
                        isLocked = false;
                        horizLockCounter = 0;

                        sweepActive = false;
                        sweepPhase  = 'idle';
                        sweepRemainingPulses = 0;
                        sweepCmd  = '';
                        sweepSign = 0;

                        set(hLock,'Visible','off');
                        set(statusTxt,'String','Done: select next pickup color');
                        write(s,'x',"char"); pause(0.02);
                        pause(0.1);
                    else
                        set(statusTxt, 'String', sprintf('Locked (%s)', colorVal));
                    end
                else
                    set(statusTxt, 'String', sprintf('Tracking (%s)', colorVal));
                end
            else
                if abs(errX) > unlockTolerancePx
                    isLocked = false;
                    horizLockCounter = 0;
                    set(hLock,'Visible','off');
                    set(statusTxt, 'String', sprintf('Tracking (%s)', colorVal));
                else
                    write(s, 'x', "char"); pause(0.01);
                    set(statusTxt, 'String', sprintf('Locked (%s)', colorVal));
                    lockedMean = [objX, objY];
                    set(hLock,'XData',lockedMean(1),'YData',lockedMean(2));
                end
            end

        else
            set(hStar,'XData',NaN,'YData',NaN);
            set(hLock,'Visible','off');
            horizLockCounter = 0;

            if isLocked
                isLocked = false;
                write(s, 'x', "char"); pause(0.02);
            end

            if strcmp(mode,'pickup')
                if ~sweepActive && (strcmp(sweepPhase,'idle') || strcmp(sweepPhase,'done'))
                    sweepActive          = true;
                    sweepPhase           = 'q';
                    sweepCmd             = 'q';
                    sweepRemainingPulses = sweepQCount;
                    sweepSign            = +1;
                    set(statusTxt,'String','Searching: sweep q');
                end

                if sweepActive
                    pulsesToSend = min([sweepPulsesPerIter, sweepRemainingPulses, maxPulsesPerLoop]);
                    for p = 1:pulsesToSend
                        if getappdata(fMain,'stopRequested'), break; end
                        write(s, sweepCmd, "char");
                        baseAngle = baseAngle + sweepSign * degPerPulseBase;
                        baseAngle = max(baseLimits(1), min(baseLimits(2), baseAngle));
                        sweepRemainingPulses = sweepRemainingPulses - 1;
                        pause(interPulsePause);
                    end

                    if sweepRemainingPulses <= 0
                        if strcmp(sweepPhase,'q')
                            sweepPhase           = 'a';
                            sweepCmd             = 'a';
                            sweepRemainingPulses = sweepACount;
                            sweepSign            = -1;
                            set(statusTxt,'String','Searching: sweep a');
                        else
                            sweepPhase           = 'done';
                            sweepActive          = false;
                            sweepRemainingPulses = 0;
                            sweepCmd             = '';
                            sweepSign            = 0;
                            set(statusTxt,'String','Searching: sweep done');
                        end
                    end

                    set(angleTxt,'String',sprintf('Base=%.1f°', baseAngle));
                    drawnow limitrate;
                    pause(loopDelay);
                    continue;
                end

            elseif strcmp(mode,'dropoff')
                write(s, 'a', "char");
                baseAngle = baseAngle - degPerPulseBase;
                baseAngle = max(baseLimits(1), min(baseLimits(2), baseAngle));
                set(statusTxt,'String','Searching: dropoff (a only)');
                set(angleTxt,'String',sprintf('Base=%.1f°', baseAngle));
                drawnow limitrate;
                pause(loopDelay);
                continue;
            end
        end

        % Base tracking
        if exist('objX','var') && ~isLocked && (strcmp(mode,'pickup') || strcmp(mode,'dropoff'))
            cx   = W/2;
            errX = cx - objX;

            if abs(errX) > lockTolerancePx
                desiredDegBase = errX / pixelsPerDegBase;
                pulses = round(abs(desiredDegBase) / degPerPulseBase);
                pulses = min(pulses, maxPulsesPerLoop);

                if pulses > 0
                    if desiredDegBase > 0
                        cmd = 'q'; signDeg = -1;
                    else
                        cmd = 'a'; signDeg = +1;
                    end

                    allowed = 0;
                    for p = 1:pulses
                        estNext = baseAngle + signDeg * degPerPulseBase;
                        if estNext < baseLimits(1) || estNext > baseLimits(2)
                            break;
                        end
                        baseAngle = estNext;
                        allowed = allowed + 1;
                    end

                    for k = 1:allowed
                        write(s, cmd, "char");
                        pause(interPulsePause);
                        if getappdata(fMain,'stopRequested'), break; end
                    end
                end
            end
        end

        set(angleTxt,'String',sprintf('Base=%.1f°', baseAngle));

        drawnow limitrate;
        pause(loopDelay);
    end

catch ME
    try
        if exist('s','var') && ~isempty(s)
            for k=1:3, write(s,'x','char'); pause(0.02); end
        end
    catch
    end
    warning("Loop stopped with error: %s", ME.message);
end

%% Cleanup
try
    if exist('s','var') && ~isempty(s)
        for k=1:3, write(s,'x','char'); pause(0.02); end
        flush(s); clear s;
    end
catch
end
if exist('cam','var') && ~isempty(cam), clear cam; end

fprintf('Stopped. Final base=%.1f\n', baseAngle);

%% Helpers

function keyPressCB(~, evt)
    if isempty(evt) || ~isfield(evt,'Key'), return; end
    if isequal(evt.Key,'escape'), emergencyStop(gcbf); end
end

function emergencyStop(figHandle)
    try
        setappdata(figHandle, 'stopRequested', true);
        s2 = getappdata(figHandle, 'serial');
        if ~isempty(s2)
            for k = 1:3
                try write(s2,'x',"char"); catch, end
                pause(0.03);
            end
        end
    catch
    end
end

function [Hmin,Hmax,Smin,Vmin] = getColorThresholds(colorName)
    switch lower(colorName)
        case 'green'
            Hmin = 0.42; Hmax = 0.5;  Smin = 0.4;  Vmin = 0.5;
        case 'red'
            Hmin = 0.90; Hmax = 1.0;  Smin = 0.40; Vmin = 0.5;
        case 'blue'
            Hmin = 0.60; Hmax = 0.71; Smin = 0.60; Vmin = 0.45;
        case 'yellow'
            Hmin = 0.10; Hmax = 0.18; Smin = 0.40; Vmin = 1.0;
        case 'purple'
            Hmin = 0.68; Hmax = 0.74; Smin = 0.20; Vmin = 0.45;
        otherwise
            Hmin = 0.25; Hmax = 0.45; Smin = 0.25; Vmin = 1.0;
    end
end

function pickup_block(s)
    shoulderDownPulses = 12;
    shoulderUpPulses   = 33;
    gripClosePulses    = 7;

    interPulseDelay = 0.15;

    shoulderDownCmd = 'r';
    shoulderUpCmd   = 'f';
    gripCloseCmd    = 'e';

    sendPulses(s, shoulderDownCmd, shoulderDownPulses, interPulseDelay);
    sendPulses(s, gripCloseCmd,    gripClosePulses,   interPulseDelay);
    sendPulses(s, shoulderUpCmd,   shoulderUpPulses,  interPulseDelay);

    try write(s, 'x', "char"); catch, end
end

function dropoff_block(s)
    shoulderDownPulses = 12;
    shoulderUpPulses   = 33;
    gripOpenPulses     = 5;
    baseForwardQPulses = 30;

    interPulseDelay = 0.15;

    shoulderDownCmd = 'r';
    shoulderUpCmd   = 'f';
    gripOpenCmd     = 'd';
    baseForwardCmd  = 'q';

    sendPulses(s, shoulderDownCmd, shoulderDownPulses, interPulseDelay);
    sendPulses(s, gripOpenCmd,     gripOpenPulses,     interPulseDelay);
    sendPulses(s, shoulderUpCmd,   shoulderUpPulses,   interPulseDelay);
    sendPulses(s, baseForwardCmd,  baseForwardQPulses, interPulseDelay);

    try write(s, 'x', "char"); catch, end
end

function sendPulses(s, cmdChar, N, interPulseDelay)
    for k = 1:N
        write(s, cmdChar, "char");
        pause(interPulseDelay);
        drawnow limitrate;  % Adjustment (1): keep UI responsive during motion
    end
end
