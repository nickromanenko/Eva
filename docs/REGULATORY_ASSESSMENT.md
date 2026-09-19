# Regulatory Assessment & Intended Use

**Drafted for counsel review.**

This document records Eva's regulatory position as a general wellness product. It outlines the intended use and serves as the claims register for features that border clinical functions.

## 1. Intended Use Statement

Eva is a software application intended solely for general wellness purposes. It is designed to help users track their menstrual cycles, log daily wellness observations (such as mood, energy, and meals), and receive general healthy-eating and lifestyle guidance. 

Eva is **not** intended for use in the diagnosis, cure, mitigation, treatment, or prevention of any disease or medical condition. It does not substitute for professional medical advice, diagnosis, or treatment. It is not intended to be used as a method of contraception or to achieve conception with stated efficacy, nor is it intended to guide clinical management or output values that mimic clinical diagnostic measurements.

## 2. Regulatory Position

### United States (FDA)
Eva falls under the enforcement discretion outlined in the FDA’s *General Wellness: Policy for Low Risk Devices* (January 2026). It meets the criteria because:
- It is intended for general wellness use (e.g., maintaining a healthy weight, tracking menstrual cycles).
- It is non-invasive and poses no inherent safety risk.
- It does not diagnose, mitigate, prevent, or treat any disease.
- It does not substitute for a cleared medical device.
- It does not guide clinical management.
- It does not output values that mimic clinical measurements (e.g., all cycle predictions are explicitly labeled as estimates, and nutrition targets are general healthy-eating guidelines).

### EU (MDR) & UK (MHRA)
Eva does not meet the definition of a medical device under the EU Medical Device Regulation (MDR) 2017/745 or the UK Medical Devices Regulations 2002. It does not possess a specific medical purpose such as the diagnosis, prevention, monitoring, treatment, or alleviation of disease. It acts as a lifestyle and wellness tracker rather than clinical decision support software.

## 3. Claims Register (General Wellness Boundaries)

The following table dictates the boundary for each feature to ensure Eva remains outside the scope of regulated medical devices. Any deviation into the "Would take it out" column requires regulatory re-assessment.

| Feature | Keeps Eva in wellness | Would take it out |
|---|---|---|
| **Cycle predictions, fertile window** | Shown as estimates with confidence; explicitly labeled "not a contraceptive method" at the point of use. | Presenting the window as contraception or conception guidance with stated efficacy. |
| **Body signals, red-flag escalation** | Deterministic "contact your provider" fallback card; no algorithmic interpretation of symptoms. | Interpreting symptoms, grading severity, or telling the user what a symptom means. |
| **Eva Chat** | General information only; explicitly refuses symptom interpretation. | Any generated answer that reads as diagnosis, triage, or clinical advice. |
| **Nutrition targets** | General healthy-eating guidance for a healthy adult; numbers derived from public health references. | Targets framed as treatment for a declared condition (e.g., diabetes, anaemia, PCOS). |
| **Pregnancy mode** | Dating and week counters provided as general information; due date explicitly labelled "estimated". | Gestational-age outputs that mimic a clinical dating ultrasound; anything that guides antenatal management. |
| **Nutrition score** | Functions solely as a qualitative meal descriptor. | A number that mimics a clinical or diagnostic value. |
| **Well-being check-in** | Non-scored conversational prompt for self-reflection (EPDS formally deferred). | Scoring a validated clinical instrument (like EPDS) and acting on or diagnosing based on the score. |


## 4. Medical Disclaimer and Methodology (A33 Override)

As per decision A33, Eva operates without continuous clinical sign-off, relying instead on published methodology and prominent disclaimers. 

### Prominent Medical Disclaimer
The app and website must display the following disclaimer prominently (e.g. at sign-up, in the Terms of Service, and in relevant coaching views):
> **Disclaimer:** Eva is a general wellness application. The information and coaching provided by Eva are for educational and informational purposes only and do not constitute medical advice, diagnosis, or treatment. Always seek the advice of your physician or other qualified health provider with any questions you may have regarding a medical condition. Do not disregard professional medical advice or delay in seeking it because of something you have read on Eva.

### Methodology and Published Research
For App Store compliance (Guideline 1.4.1), all calculations must disclose their methodology transparently. The methodology refers to peer-reviewed sources (documented in `api/.env.example` and the product documentation), including:
- **Cycle tracking:** FIGO AUB System 1 (Munro et al., Int J Gynecol Obstet 2018) and Wilcox et al., BMJ 2000.
- **Nutrition (BMR & Activity):** Mifflin-St Jeor (Am J Clin Nutr 1990).
- **Nutrition (Protein & Macros):** Phillips SM & Van Loon LJC (J Sports Sci 2011), Jäger R et al. (JISSN 2017), Dietary Guidelines for Americans (2020-2025).
- **Nutrition (Weight Guards):** WHO Technical Report Series 894 (2000) for BMI floors. 
