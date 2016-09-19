function [ber, Analog, S, Sf] = ber_coherent_analog_opll_qpsk(Tx, Fiber, Rx, sim)
%% Calculate BER of DP-QPSK coherent system with analog-based receiver for values of launched power specified Tx.PlaunchdB
%% Carrier phase recovery is done either with feedforward or EPLL with phase estimation done via electric PLL based on XOR operations

Qpsk = sim.ModFormat;
Analog = Rx.Analog;

% Ensures that modulation format is QPSK
assert(strcmpi(class(Qpsk), 'QAM') && Qpsk.M == 4, 'ber_coherent_analog: Modulation format must be QPSK')

% Converts delay to number of samples in order to avoid interpolation
additionalDelay = max(round(Analog.Delay*sim.fs), 1); % delay is at least one sample
LOFMgroupDelay = round(Rx.LOFMgroupDelayps/1e12*sim.fs);

% Create components
% Receiver filter
ReceiverFilterXI = ClassFilter(Analog.filt);
ReceiverFilterXQ = ClassFilter(Analog.filt);
ReceiverFilterYI = ClassFilter(Analog.filt);
ReceiverFilterYQ = ClassFilter(Analog.filt);

Comp1 = AnalogComparator(Analog.Comparator.filt, Analog.Comparator.N0, sim.fs, Analog.Comparator.Vcc);
Comp2 = AnalogComparator(Analog.Comparator.filt, Analog.Comparator.N0, sim.fs, Analog.Comparator.Vcc);
Comp3 = AnalogComparator(Analog.Comparator.filt, Analog.Comparator.N0, sim.fs, Analog.Comparator.Vcc);
Comp4 = AnalogComparator(Analog.Comparator.filt, Analog.Comparator.N0, sim.fs, Analog.Comparator.Vcc);

AdderXY = AnalogAdder(Analog.Adder.filt, Analog.Adder.N0, sim.fs);

Costas = false;
switch lower(Analog.CPRmethod)
    case 'costas'
        Costas = true;
        MixerIdQx = AnalogMixer(Analog.Mixer.filt, Analog.Mixer.N0, sim.fs);
        MixerQdIx = AnalogMixer(Analog.Mixer.filt, Analog.Mixer.N0, sim.fs);
        MixerIdQy = AnalogMixer(Analog.Mixer.filt, Analog.Mixer.N0, sim.fs);
        MixerQdIy = AnalogMixer(Analog.Mixer.filt, Analog.Mixer.N0, sim.fs);

        AdderX = AnalogAdder(Analog.Adder.filt, Analog.Adder.N0, sim.fs);
        AdderY = AnalogAdder(Analog.Adder.filt, Analog.Adder.N0, sim.fs);
        
        % Calculate group delay in s
        totalGroupDelay = LOFMgroupDelay/sim.fs... % Laser FM response delay
            + ReceiverFilterXI.groupDelay/sim.fs... % Receiver filter
            + Comp1.groupDelay + MixerIdQx.groupDelay + AdderX.groupDelay + AdderXY.groupDelay... % phase estimation    
            + additionalDelay/sim.fs; % Additional loop delay e.g., propagation delay (minimum is 1/sim.fs since simulation is done in discrete time)
        fprintf('Total loop delay: %.3f ps (%.2f bits, %d samples)\n', totalGroupDelay*1e12, totalGroupDelay*sim.Rb, ceil(totalGroupDelay*sim.fs));       
    case 'logic'
        % Full wave rectifiers (absolute operation)
        abs1 = AnalogABS(Analog.ABS.filt, Analog.ABS.N0, sim.fs);
        abs2 = AnalogABS(Analog.ABS.filt, Analog.ABS.N0, sim.fs);
        abs3 = AnalogABS(Analog.ABS.filt, Analog.ABS.N0, sim.fs);
        abs4 = AnalogABS(Analog.ABS.filt, Analog.ABS.N0, sim.fs);

        % Comparators
        CompX = AnalogComparator(Analog.Comparator.filt, Analog.Comparator.N0, sim.fs, Analog.Comparator.Vcc);
        CompY = AnalogComparator(Analog.Comparator.filt, Analog.Comparator.N0, sim.fs, Analog.Comparator.Vcc);

        % xnor
        xnorX1 = AnalogLogic(Analog.Logic.filt, Analog.Logic.N0, sim.fs);
        xnorX2 = AnalogLogic(Analog.Logic.filt, Analog.Logic.N0, sim.fs);
        xnorY1 = AnalogLogic(Analog.Logic.filt, Analog.Logic.N0, sim.fs);
        xnorY2 = AnalogLogic(Analog.Logic.filt, Analog.Logic.N0, sim.fs);
        
        % Calculate group delay in s
        totalGroupDelay = LOFMgroupDelay/sim.fs... % Laser FM response delay
            + ReceiverFilterXI.groupDelay/sim.fs... % Receiver filter
            + Comp1.groupDelay + xnorX1.groupDelay + xnorX2.groupDelay + AdderXY.groupDelay... % phase estimation    
            + additionalDelay/sim.fs; % Additional loop delay e.g., propagation delay (minimum is 1/sim.fs since simulation is done in discrete time)
        fprintf('Total loop delay: %.3f ps (%.2f bits, %d samples)\n', totalGroupDelay*1e12, totalGroupDelay*sim.Rb, ceil(totalGroupDelay*sim.fs));
    otherwise
        error('ber_coherent_analog_opll_qpsk: invalid carrier phase recovery method. Analog.CPRmethod must be either Costas or Logic')
end

% Optimize EPLL parameters
totalLineWidth = Tx.Laser.linewidth + Rx.LO.linewidth;
if not(isfield(Analog, 'wn')) % wn was not yet defined; calculate optimal wn
    Analog.wn = optimizePLL(Analog.csi, totalGroupDelay, totalLineWidth, sim, sim.shouldPlot('Phase error variance'));
end
Analog.EPLL.nums = [2*Analog.csi*Analog.wn Analog.wn^2];
Analog.EPLL.dens = [1 0 0]; % descending powers of s
[Analog.EPLL.numz, Analog.EPLL.denz] = impinvar(Analog.EPLL.nums, Analog.EPLL.dens, sim.fs);
fprintf('Loop filter fn: %.3f GHz\n', Analog.wn/(2*pi*1e9));

% Loop filter
LoopFilter = ClassFilter(Analog.EPLL.numz, Analog.EPLL.denz, sim.fs);

%% Generate transmitted symbols
% Note 1: this implement assumes that no DAC is being used so ModFormat.signal
% generates rectangular pulses sampled at sim.fs
% Note 2: ModFormat.signal does not remove group delay due to pulse shaping
% so the center of the pulse is at (Mct+1)/2, if pulse shape is 'rect'
dataTX = randi([0 Qpsk.M-1], [2, sim.Nsymb]); % symbol stream for each polarization
Nzero = 10; % zero Nzero first and last symbols to make sequence periodic
dataTX(:, 1:Nzero) = 0;
dataTX(:, end-Nzero+1:end) = 0;

[Vin, symbolsTX] = Qpsk.signal(dataTX); % X & Y pol

% Filter drive waveforms for modulators txfilt.
% group delay of Tx.filt.H has already been removed
Htx = ifftshift(Tx.filt.H(sim.f/sim.fs).*exp(1j*2*pi*sim.f/sim.fs*(Qpsk.pulse_shape_grpdelay))); % transmitter filter and remove group delay due to pulse shaping in ModFormat
Vout(1, :) = real(ifft(fft(real(Vin(1, :))).*Htx)) + 1j*real(ifft(fft(imag(Vin(1, :))).*Htx)); 
Vout(2, :)= real(ifft(fft(real(Vin(2, :))).*Htx)) + 1j*real(ifft(fft(imag(Vin(2, :))).*Htx));

% BER of ideal system with receiver filtering equal to matched filter
[ber.theory, ber.theory_noise_enhancement] = ber_coherent_awgn(Tx, Fiber, Rx, sim);

%% Swipe launched power
ber.count = zeros(size(Tx.PlaunchdBm));
counter = 1;
for k = 1:length(Tx.PlaunchdBm)
    fprintf('-- Launch power: %.2f dBm\n', Tx.PlaunchdBm(k));
    
    %% ========= Modulator ==========
    Tx.Laser.PdBm = Tx.PlaunchdBm(k);
    Ein = Tx.Laser.cw(sim); % Generates electric field with intensity and phase noise
    Ein = mzm(Ein, Vout, Tx.Mod); % modulate optical signal using eletro-optical modulator (EOM)
    
    % Ensure that transmitted power is at desired level
    Ein = Ein*sqrt(dBm2Watt(Tx.PlaunchdBm(k))/sum(mean(abs(Ein).^2, 2)));

    %% ========= Propagation ==========
    Fiber.PMD = false; 
    % Note: since polarization demultiplexing is not done here, the fiber
    % must maitain polarization states.
    Erec = Fiber.linear_propagation(Ein, sim.f, Tx.Laser.lambda);
    
    %% ========= Receiver =============
    ELO = Rx.LO.cw(sim); % generates continuous-wave electric field in 1 pol with intensity and phase noise
    ELO = [sqrt(1/2)*ELO;    % LO field in x polarization at PBS or BS input
           sqrt(1/2)*ELO];    % LO field in y polarization at PBS or BS input
       
    %% Loop
    Yrx = zeros(size(Erec));
    X = zeros(4, length(sim.t));
    Xd = zeros(4, length(sim.t));
    S = zeros(size(sim.t));
    Sf = zeros(size(sim.t));
    M = Qpsk.M;
    Enorm = mean(abs(pammod(0:log2(M)-1, log2(M))).^2);
    Px = zeros(4, 1);
    for t = LOFMgroupDelay+additionalDelay+1:size(Erec, 2)
        % Ajust LO phase
        ELO(:, t) = ELO(:, t).*exp(-1j*Sf(t-additionalDelay-LOFMgroupDelay));
        
        % Coherent detection
        Yrx(:, t) = dual_pol_coherent_receiver(Erec(:, t), ELO(:, t), Rx, sim);
    
        % Receiver filter
        X(1, t) = ReceiverFilterXI.filter(real(Yrx(1, t)));
        X(2, t) = ReceiverFilterXQ.filter(imag(Yrx(1, t)));
        X(3, t) = ReceiverFilterYI.filter(real(Yrx(2, t)));
        X(4, t) = ReceiverFilterYQ.filter(imag(Yrx(2, t)));
        
        % Automatic gain control (AGC)
        Px = (t-1)/t*Px + 1/t*abs(X(:, t)).^2;
        X(:, t) = sqrt(Enorm./Px).*X(:, t);
        
        % Phase estimation
        Xd(1, t) = Comp1.compare(X(1, t), Analog.Comparator.Vref);
        Xd(2, t) = Comp2.compare(X(2, t), Analog.Comparator.Vref);
        Xd(3, t) = Comp3.compare(X(3, t), Analog.Comparator.Vref);
        Xd(4, t) = Comp4.compare(X(4, t), Analog.Comparator.Vref);
        
        if Costas % Costas loop operations
            Sx = AdderX.add(MixerIdQx.mix(Xd(1, t), X(2, t)), -MixerQdIx.mix(Xd(2, t), X(1, t)));
            Sy = AdderY.add(MixerIdQy.mix(Xd(3, t), X(4, t)), -MixerQdIy.mix(Xd(4, t), X(3, t))); 
        else % Logic or XOR-based
            Xdabs(1) = abs1.abs(X(1, t));
            Xdabs(2) = abs2.abs(X(2, t));
            Xdabs(3) = abs3.abs(X(3, t));
            Xdabs(4) = abs4.abs(X(4, t));

            Sx = xnorX2.xnor(xnorX1.xnor(Xd(1, t), Xd(2, t)), CompX.compare(Xdabs(1), Xdabs(2)));
            Sy = xnorY2.xnor(xnorY1.xnor(Xd(3, t), Xd(4, t)), CompY.compare(Xdabs(3), Xdabs(4)));
        end

%         StempX(t) = Sx;
%         StempY(t) = Sy;
%         
        % Loop filter
        if Analog.CPRNpol == 2
            S(t) = AdderXY.add(Sx, Sy); % loop filter input
        else
            S(t) = Sx; % loop filter input
        end
        Sf(t) = LoopFilter.filter(S(t));  
    end
    
%     figure, plot(StempX)
%     hold on, plot(StempY)    
%     ccorr = xcorr(StempX, StempY, 50);
%     figure, plot(-50:50, ccorr)
%     drawnow
    
    % Remove group delay due to loop filter
    Hdelay = ifftshift(exp(1j*2*pi*sim.f/sim.fs*ReceiverFilterXI.groupDelay));
    X(1, :) = real(ifft(fft(X(1, :)).*Hdelay ));
    X(2, :) = real(ifft(fft(X(2, :)).*Hdelay ));
    X(3, :) = real(ifft(fft(X(3, :)).*Hdelay ));
    X(4, :) = real(ifft(fft(X(4, :)).*Hdelay ));
    
    % Build output
    Xt = [X(1, :) + 1j*X(2, :); X(3, :) + 1j*X(4, :)];   
    
    %% Time recovery and sampling
    % Note: clock obtained from I is used in Q in order to prevent
    % differences in sampling between I and Q
    [Xk(1, :), ~, Nsetup] = analog_time_recovery(Xt(1, :), Rx.TimeRec, sim, sim.shouldPlot('Time recovery'));
    Xk(2, :) = analog_time_recovery(Xt(2, :), Rx.TimeRec, sim);
       
    % Automatic gain control
    Xk = [sqrt(2/mean(abs(Xk(1, :)).^2))*Xk(1, :);
         sqrt(2/mean(abs(Xk(2, :)).^2))*Xk(2, :)];
    
    %% Align received sequence and correct for phase rotation
    [c(1, :), ind] = xcorr(symbolsTX(1, :), Xk(1, :), 20, 'coeff');
    c(2, :) = xcorr(symbolsTX(2, :), Xk(2, :), 20, 'coeff');
       
    % maximum correlation position
    [~, p] = max(abs(c), [], 2);
    theta = [angle(c(1, p(1))), angle(c(2, p(2)))];
    
    % Circularly shift symbol sequence
    Xk = [circshift(Xk(1, :), [0 ind(p(1))]);...
        circshift(Xk(2, :), [0 ind(p(2))])];
       
    % Rotate constellations
    Xk = [Xk(1, :).*exp(+1j*theta(1)); Xk(2, :).*exp(+1j*theta(2))];
           
    fprintf('> X pol signal was shifted by %d samples\n', ind(p(1)))
    fprintf('> Y pol signal was shifted by %d samples\n', ind(p(2)))
    fprintf('> X pol constellation was rotated by %.2f deg\n', rad2deg(theta(1)))
    fprintf('> Y pol constellation was rotated by %.2f deg\n', rad2deg(theta(2)))
    
    %% Detection
    dataRX = Qpsk.demod(Xk);
    
    % Valid range for BER measurement
    validInd = sim.Ndiscard+Nsetup(1)+1:sim.Nsymb-sim.Ndiscard-Nsetup(2);
        
    % BER calculation
    [~, berX(k)] = biterr(dataTX(1, validInd), dataRX(1, validInd))
    [~, berY(k)] = biterr(dataTX(2, validInd), dataRX(2, validInd))
    ber.count(k) = 0.5*(berX(k) + berY(k));
    
   % Constellation plots
   if sim.shouldPlot('Constellations')
       figure(203), clf 
       subplot(121)
       plot_constellation(Xk(1, validInd), dataTX(1, validInd), Qpsk.M);
       axis square
       title('Pol X') 
       subplot(122)
       plot_constellation(Xk(2, validInd), dataTX(2, validInd), Qpsk.M);
       axis square
       title('Pol Y')   
       drawnow
   end 
   
   if sim.shouldPlot('Symbol errors')
        figure(204), clf
        subplot(121)
        stem(dataTX(1, validInd) ~= dataRX(1, validInd))
        title('Pol X')       
        subplot(122)
        stem(dataTX(2, validInd) ~= dataRX(2, validInd))
        title('Pol Y')   
        drawnow
   end
   
   % Stop simulation when counted BER reaches 0
   if sim.stopWhenBERreaches0 && ber.count(k) == 0
       break
   end
   
   % Stop simulation when counted BER stays above 0.3 for 3 times
   if ber.count(k) >= 0.3       
       if counter == 3
           break;
       end
       counter = counter + 1;
   end          
end

plots

%% Plot BER curve
if sim.shouldPlot('BER') && length(ber.count) > 1
    figure(100), box on, hold on
    [~, link_attdB] = Fiber.link_attenuation(Tx.Laser.lambda);
    Prx = Tx.PlaunchdBm - link_attdB;
    hline(1) = plot(Prx, log10(ber.theory), '-');
    hline(2) = plot(Prx, log10(ber.count), '-o');
    legend(hline, {'Theory', 'Counted'})
    xlabel('Received Power (dBm)')
    ylabel('log_{10}(BER)')
    axis([Prx(1) Prx(end) -8 0])
end

%% Phase error plot
if sim.shouldPlot('Phase error')
    figure(404), clf
    subplot(211), hold on, box on
    plot(sim.t, S)
    xlabel('time (s)')
    ylabel('Loop filter input')       
    subplot(212), hold on, box on
    plot(sim.t, Sf)
    p = polyfit(sim.t, Sf, 1);
    plot(sim.t, polyval(p, sim.t));
    legend('VCO phase', sprintf('Linear fit (for freq offset) = %.2f GHz ramp', p(1)/(2*pi*1e9)))
    xlabel('time (s)')
    ylabel('Phase (rad)')
end
    
